# Revisao do Head #1 (21/09/2026) — o que ja corrigi e o que falta

JA CORRIGIDO pelo Head na migration: event_map.funnel_step agora NULL nos 6 codigos. Motivo: o evento GHL mais recente de cada codigo em producao tem funnel_step NULL (a ponte antiga copiava isso); usar 1..6 mudaria o vocabulario. Paridade primeiro. Nao reverta.

FALTA (voce faz), so no arquivo supabase/acceptance/imp216-acceptance.sql (e isolamento se preciso):
1. O ImpulsHub (3ec294db-...) TEM ghl_location_id preenchido em producao. O aceite precisa simular "cliente SEM GHL": dentro da transacao, como postgres, `update public.clients_base set ghl_location_id = null, ghl_location_name = null where id = '3ec294db-...'` antes do movimento (tudo termina em ROLLBACK). Confirme antes se clients_base.ghl_location_id aceita null; se nao aceitar, use um valor vazio '' (a funcao usa btrim/length) e diga qual.
2. Trocar a asserção "after_count = 0" por DELTA: contar antes do movimento e exigir exatamente +1 para o ImpulsHub, e conversion_outbox +0.
3. Provar variacao ZERO de verdade nos clientes GHL: mover um card de Royal (fa6fc071-...) para a proxima etapa (fixture dinamica, mesmo padrao) e exigir delta 0 em events_normalized (source_system='impuls_crm') e conversion_outbox para Royal. Repita para Central se houver card elegivel. Autor da acao: usuario agency Caio d036c4d6-... (tem acesso a todos).
4. Caso extra: com crm_emits_conversions ligada num tenant sintetico DENTRO da transacao e ghl_location_id vazio, mover card deve levantar a excecao 'IMP-216 ghl_location_id is required only for conversion emission' (use begin/exception num do-block com savepoint) — prova que a ponte de conversao continua exigindo GHL.
5. Depois: commit, git push, atualize o corpo do PR #13 e pare. Nao execute nada em banco.
