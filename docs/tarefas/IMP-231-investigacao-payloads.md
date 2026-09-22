# IMP-231 — Investigação somente-leitura de payloads brutos

Data da medição: 22/09/2026
Projeto consultado: `Clients_Base` (`mtxnwtqwfagjzkvgsncs`)
Escopo: somente `SELECT`, em transação `READ ONLY`, sem escrita em produção ou staging.

## Medições do catálogo e dos dados

O tamanho de TOAST abaixo é `pg_total_relation_size(reltoastrelid)`; o tamanho
`total` é `pg_total_relation_size` da tabela. Os valores foram calculados a
partir dos bytes retornados pelo catálogo, em MiB (1 MiB = 1.048.576 bytes).

| Tabela | Coluna(s) bruta(s) confirmada(s) | Linhas | Total | TOAST | Recomendação |
|---|---|---:|---:|---:|---|
| `public.meta_ads_daily` | 9 jsonb: `source_payload`, `ad_raw`, `creative_raw`, `asset_feed_spec`, `object_story_spec`, `actions_raw`, `conversions_raw`, `action_values_raw`, `conversion_values_raw` | 10.100 | 35,45 MiB | 13,39 MiB | Retenção de 14 dias segura para os nove payloads, já formalizada pela IMP-231; os campos estruturados de mídia permanecem. |
| `public.stevo_events_raw` | `payload` jsonb; também `headers` e `query_params` jsonb | 49.171 | 129,84 MiB | 33,64 MiB | Não é seguro propor limpeza semelhante agora: `payload_hash` é usado pelo parser e copiado para `crm.processed_events`, além de `payload` sustentar a interpretação da mensagem. Exige política própria de replay/auditoria antes de qualquer retenção. |
| `public.events_raw` | `payload`, `request_body`, `request_headers`, `request_query` jsonb | 17.721 | 98,23 MiB | 74,26 MiB | Não é seguro apagar automaticamente nesta investigação: é camada técnica de entrada/auditoria e pode ser necessária para replay e diagnóstico. Primeiro definir retenção por origem/status e confirmar dependências ativas. |
| `public.events_normalized` | `payload` e `normalized_payload` jsonb | 15.158 | 76,18 MiB | 51,25 MiB | Não é seguro apagar automaticamente: a tabela é a camada normalizada consumida pelo dashboard e contém colunas estruturadas, mas não foi provada equivalência completa nem ausência de uso dos jsonb para auditoria/reprocessamento. |

A consulta de `information_schema.columns` confirmou que em `events_normalized`
existem as duas colunas (`payload` e `normalized_payload`); não foi usado nome
presumido.

## Uso ativo confirmado no Stevo

A definição atual de `crm.stevo_parse_messages(integer)` foi lida com
`pg_get_functiondef`. Ela seleciona `r.payload` e `r.payload_hash` de
`public.stevo_events_raw`, grava `ev.payload_hash` em
`crm.processed_events`, e marca o raw como `duplicate`/`processed`. Portanto,
o raw não é apenas armazenamento redundante: o hash participa da deduplicação
e o payload participa do parsing.

## Cron observado

O único job existente relacionado é `crm-stevo-parser`, com schedule `* * * * *`
e comando `select crm.stevo_parse_messages(2000);`. A IMP-231 escolhe nome
separado (`meta-ads-raw-retention-daily`) e horário diário `15 3 * * *` (03:15
UTC), fora do intervalo de maior tráfego presumido. O job não executa `VACUUM
FULL`.

## Conclusão

Apenas `meta_ads_daily` entra nesta entrega. Os três payloads de eventos ficam
como candidatos futuros, sem migration, limpeza ou alteração. Qualquer proposta
posterior deve medir dependências de replay/auditoria, definir janela por
origem e provar que o dado estruturado equivalente já existe antes de zerar o
jsonb.
