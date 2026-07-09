# Scripts SQL — histórico de migrações

Aplicados nesta ordem no Supabase (SQL Editor). Cada um resolveu um problema real
encontrado durante a construção — os comentários de cada arquivo explicam o porquê.

1. `01_views_mvp.sql` — views iniciais do MVP: Meta/Google diário com conta,
   contas de anúncio, leads por etapa, eventos recentes.
2. `02_views_meta_conversions.sql` — adiciona Conversões Meta (plataforma) e
   CRM leads/agendados nas views de Meta e Google.
3. `03_add_entrada.sql` — adiciona `lead_entrada` às views de leads e eventos.
4. `04_fix_funnel.sql` — corrige `v_crm_funnel_daily`, que contava primeira
   conversa/agendado/ganho a partir da `v_crm_opportunities` (poucas linhas,
   datas de etapa nem sempre preenchidas) em vez dos eventos reais.

Convenções usadas em todas as views:
- `security_invoker = true` sempre — para herdar a RLS do usuário real.
- `GRANT SELECT ... TO authenticated` sempre no final de cada script — visto
  que `CREATE OR REPLACE VIEW` preserva grants, mas `DROP + CREATE` os perde.
- Ao mudar as colunas de uma view existente, usar `DROP VIEW` antes de recriar
  (o Postgres não permite `CREATE OR REPLACE` mudar a lista de colunas).
