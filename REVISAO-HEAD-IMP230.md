# Revisao do Head — IMP-230 (22/09/2026, madrugada)

Corrigido pelo Head, tudo já commitado e provado em staging (migration + aceite +
isolamento + rollback, negativo confere):

1. **Bug que quebraria a feature inteira em produção:** a Edge Function chamava
   `db.schema("crm").rpc("intake_form_lead", ...)`, mas este projeto só expõe o
   schema `public` ao PostgREST (é por isso que `crm_move_stage`, `crm_register_won`
   etc. vivem em `public`, não em `crm`, mesmo escrevendo em tabelas `crm.*`).
   Renomeei a função para `public.intake_form_lead` e ajustei a Edge Function
   (`db.rpc("intake_form_lead", ...)`, sem `.schema("crm")`). Sem isso, toda
   submissão do formulário falharia com 404/erro de schema.
2. **Staging estava desatualizado:** a IMP-216 nunca tinha sido commitada de
   verdade lá (só provada em transações com rollback). Apliquei a migration da
   216 de forma durável em `nfratueiutxnypbxfnmi` antes de provar a 230 em cima
   dela — staging agora reflete produção.
3. **Card nascia sem histórico inicial:** `intake_form_lead` não gravava
   `crm.opportunity_stage_history`, diferente de todo o resto do sistema (a
   restrição do banco só cobre UPDATE, não INSERT, então não quebrava — mas a
   aba de histórico do card nasceria vazia). Adicionei o insert do histórico
   inicial, mesmo padrão usado no resto do projeto.
4. **Rollback:** faltava `set constraints all immediate` antes do
   `ALTER TABLE ... DROP COLUMN` em `crm.opportunities` — sem isso, rollback
   na mesma transação do aceite falhava com "pending trigger events" (mesma
   classe de bug que já documentamos no AGENTS.md). Corrigido.

**O que ficou bom sem eu mexer:** ACL fechada (nada novo para `anon`), token por
cliente, honeypot e rate-limit (IP + token) na Edge Function, truncamento de
payload em todos os campos de texto antes de chegar no Postgres (isso evita
reabrir o mesmo problema de TOAST/disk que resolvemos hoje com a IMP-231),
resposta genérica e uniforme para token inválido/rate-limit/erro (não dá pista
para quem tenta adivinhar).

**Não implementado nesta rodada, por decisão da ADR:** captcha, HTML do
formulário em si, deploy da Edge Function (fica para quando o Caio autorizar).

**Ainda precisa do Caio:**
1. Revisar esta PR (especialmente a ACL e a Edge Function, por ser a primeira
   porta pública do sistema).
2. Autorizar aplicar `supabase/acceptance/APLICAR-imp230.sql` em produção.
3. Autorizar `supabase functions deploy form-intake` em produção.
4. Decidir/gerar o HTML do formulário para o site do cliente (fora do escopo
   desta entrega).
