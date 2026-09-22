# Revisao do Head — IMP-231 (22/09/2026, madrugada)

Corrigido pelo Head, provado em staging (migration + aceite + rollback do job
numa transacao, negativo confere):

1. **Colisao de timestamp com a IMP-230:** os dois executores pegaram
   `20261001000000` ao mesmo tempo (branches irmas, mesmo ponto de partida).
   Renomeei esta para `20261002000000` (migration, rollback, ledger no
   APLICAR).
2. **Gate/aceite quebravam por formatacao, nao por conteudo:** a comparacao
   textual do comando do job colapsava espacos em vez de remove-los, e o
   corpo do job foi escrito com quebras de linha diferentes na migration vs.
   no APLICAR-imp231.sql (um tinha "and (source_payload", outro "and (
   source_payload"). Troquei a normalizacao para remover TODO espaco em
   branco antes de comparar — resistente a como cada arquivo quebra linha.
3. **Nota errada no aceite:** dizia que `meta_ads_daily` "nao tem client_id" —
   tem (e usado na chave unica de dedupe). Corrigi o comentario; o teste de
   isolamento continua nao se aplicando (job interno, sem RLS de usuario).
4. **Staging ficou vazio depois de eu pausar/restaurar** (achado sério, ver
   nota geral no HANDOFF): tive que recriar so a tabela `meta_ads_daily`
   (extraida da definicao viva de producao) para provar esta IMP.

**Achado sem correcao necessaria:** a investigacao das 3 tabelas
(stevo_events_raw/events_raw/events_normalized) esta cautelosa e correta —
nao implementa nada, so recomenda estudo futuro. Concordo com a recomendacao.

**Ainda precisa do Caio:**
1. Revisar o PR.
2. Autorizar aplicar `supabase/acceptance/APLICAR-imp231.sql` em producao
   (cria o job pg_cron as 03:15 UTC; zero linhas devem mudar, ja que o Head
   ja fez a limpeza manual — o gate confere isso).
