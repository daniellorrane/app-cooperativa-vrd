// Função de envio de notificações push (Web Push com chaves VAPID).
// Chamada pelo banco a cada notificação criada. Só aceita requisições com o segredo PUSH_SECRET.
// O texto enviado é o título genérico da notificação (sem assunto nem conteúdo das mensagens), por LGPD.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT")!,
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Método não permitido", { status: 405 });
  }
  if (req.headers.get("x-push-secret") !== Deno.env.get("PUSH_SECRET")) {
    return new Response("Proibido", { status: 403 });
  }

  const corpo = await req.json().catch(() => null);
  const notificacaoId = corpo?.notificacao_id;
  if (!notificacaoId) {
    return new Response("Requisição inválida", { status: 400 });
  }

  const { data: notificacao } = await sb
    .from("notificacoes")
    .select("id, usuario_id, titulo, conversa_id")
    .eq("id", notificacaoId)
    .maybeSingle();
  if (!notificacao) {
    return new Response("Notificação não encontrada", { status: 404 });
  }

  const { data: aparelhos } = await sb
    .from("push_inscricoes")
    .select("id, endpoint, p256dh, auth")
    .eq("usuario_id", notificacao.usuario_id);

  // Texto sempre genérico: nem o título nem o conteúdo do aviso saem do sistema (LGPD).
  const payload = JSON.stringify({
    titulo: "Cooperativa Vale do Rio Doce",
    corpo: "Você tem uma nova atualização no sistema.",
    url: notificacao.conversa_id ? `/#conversa/${notificacao.conversa_id}` : "/#notificacoes",
  });

  let enviados = 0;
  let removidos = 0;
  await Promise.all((aparelhos ?? []).map(async (aparelho) => {
    try {
      await webpush.sendNotification(
        { endpoint: aparelho.endpoint, keys: { p256dh: aparelho.p256dh, auth: aparelho.auth } },
        payload,
        { TTL: 86400 },
      );
      enviados++;
    } catch (erro) {
      // 404 ou 410: a inscrição expirou ou foi revogada no navegador. Remove para não tentar de novo.
      if (erro?.statusCode === 404 || erro?.statusCode === 410) {
        await sb.from("push_inscricoes").delete().eq("id", aparelho.id);
        removidos++;
      }
    }
  }));

  return Response.json({ enviados, removidos });
});
