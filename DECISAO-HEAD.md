# Decisao do Head (21/09/2026) — desbloqueia o Passo 0 da IMP-216

Verificado em producao, so leitura:
- events_normalized.ghl_location_id e NOT NULL. Nada de resultados depende dele: so 2 indices (idx_events_normalized_ghl_location_id, idx_events_normalized_location_event), 2 views de auditoria interna (v_event_tracking_audit, v_tracking_runtime_health) e a funcao public.get_internal_operations_feed. Nenhuma aba de resultados usa.
- conversion_outbox.ghl_location_id tambem e NOT NULL, mas so e escrito com crm_emits_conversions ligada (fora de escopo): NAO mexer.

DECISOES:
1. Incluir na migration `alter table public.events_normalized alter column ghl_location_id drop not null;` (operacao so de metadados). Rollback: `set not null` SO se nao houver linhas nulas; se houver, o rollback deve abortar com mensagem clara (ou apagar apenas as linhas impuls_crm com ghl_location_id nulo, declarado no comentario — escolha a segunda e declare).
2. Sem GHL: escrever events_raw/events_normalized com ghl_location_id NULL (location_id e location_name tambem NULL). Com GHL: continua gravando como hoje.
3. GOOGLE: fora desta entrega. As colunas gclid/gbraid/wbraid/utm_* existem em events_normalized, mas nao em crm.opportunities; isso vem com a IMP-230. Entregar SO a origem Meta e deixar um comentario no codigo e no PR: "origem Google: IMP-230". Nao inventar coluna.
4. Nome do evento/funnel_step: mapa versionado proprio do CRM (tabela nova em schema crm, ex.: crm.event_map com version, stage_code, event_code, event_name, funnel_step; RLS ligada, sem acesso a anon/authenticated alem do necessario; seed com os 6 codigos lead, primeira_conversa, agendado, compareceu, ganho, perdido usando os MESMOS event_name/funnel_step vigentes hoje do GHL para nao mudar vocabulario do dashboard). Nada de ler events_normalized de terceiros.
5. Flag nova: public.clients_base.crm_feeds_dashboard boolean not null default true, com Royal, Central e QuickClean EXPLICITAMENTE false (ids no task file / AGENTS.md). Gate confere os tres false. ImpulsHub (3ec294db-...) fica true.
6. Ordem no trigger: (a) sem flag de dashboard E sem flag de conversao => return new; (b) dashboard true => escreve events_raw + events_normalized; (c) conversao true => escreve conversion_outbox como hoje (e ai continua exigindo ghl_location_id). Variacao ZERO para os 3 clientes GHL (todas as flags como estao hoje).
7. Aceite deve provar: 3 clientes GHL com contagem identica antes/depois em events_normalized e conversion_outbox; cliente sem GHL move card, +1 linha em events_normalized, 0 em conversion_outbox; reentrada = no-op; isolamento.

Continue no PR #13 (mesma branch). Ainda: NAO execute a migration em lugar nenhum; so arquivos + dry-run.
