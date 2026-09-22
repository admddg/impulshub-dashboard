-- IMP-230 isolamento entre clientes. Executar depois da migration; termina em ROLLBACK.
begin;
set local statement_timeout = '8s';
set local role postgres;
do $isolation$
declare v_slug text; v_token uuid; v_tenant uuid; v_result jsonb; v_opp uuid;
begin
  select cb.client_slug, cb.form_intake_token, cb.id into v_slug,v_token,v_tenant from public.clients_base cb where cb.id='3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;
  v_result := public.intake_form_lead(v_slug,v_token,'IMP230 isolamento','5511977777777','imp230-isolation@example.invalid',null,null,null,'google','cpc','isolamento',null,null,null);
  v_opp := (v_result->>'opportunity_id')::uuid;
  if not exists (select 1 from crm.opportunities o where o.id=v_opp and o.tenant_id=v_tenant and o.contact_id in (select c.id from crm.contacts c where c.tenant_id=v_tenant)) then raise exception 'IMP230_ISOLATION: oportunidade/contact tenant mismatch'; end if;
  if exists (select 1 from crm.opportunities o where o.id=v_opp and o.tenant_id<>v_tenant) then raise exception 'IMP230_ISOLATION: oportunidade em tenant cruzado'; end if;
  raise notice 'IMP230_ISOLATION OK: tenant=% oportunidade=%',v_tenant,v_opp;
end
$isolation$;
rollback;
