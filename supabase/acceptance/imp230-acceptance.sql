-- IMP-230 aceite transacional. Executar depois da migration; termina em ROLLBACK.
begin;
set local statement_timeout = '8s';
set local role postgres;
do $test$
declare
  v_slug text; v_token uuid; v_tenant uuid; v_contact_before integer; v_opp_before integer;
  v_contact_after integer; v_opp_after integer; v_opp uuid; v_result jsonb;
begin
  select cb.client_slug, cb.form_intake_token, cb.id into v_slug, v_token, v_tenant
    from public.clients_base cb where cb.id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;
  if v_token is null then raise exception 'IMP230_ACCEPT: tenant fixture/token ausente'; end if;
  select count(*) into v_contact_before from crm.contacts where tenant_id=v_tenant and email='imp230-accept@example.invalid';
  select count(*) into v_opp_before from crm.opportunities where tenant_id=v_tenant and title='IMP230 aceite';
  v_result := public.intake_form_lead(v_slug,v_token,'IMP230 aceite','5511999999999','imp230-accept@example.invalid','gclid-imp230','gbraid-imp230','wbraid-imp230','google','cpc','campanha','conteudo','termo','https://example.invalid/landing');
  v_result := public.intake_form_lead(v_slug,v_token,'IMP230 aceite','5511999999999','imp230-accept@example.invalid','gclid-imp230','gbraid-imp230','wbraid-imp230','google','cpc','campanha','conteudo','termo','https://example.invalid/landing');
  select count(*) into v_contact_after from crm.contacts where tenant_id=v_tenant and email='imp230-accept@example.invalid';
  select count(*) into v_opp_after from crm.opportunities where tenant_id=v_tenant and title='IMP230 aceite';
  if v_contact_after-v_contact_before <> 1 then raise exception 'IMP230_ACCEPT: contatos esperados 1, obtidos %',v_contact_after-v_contact_before; end if;
  if v_opp_after-v_opp_before <> 1 then raise exception 'IMP230_ACCEPT: oportunidades esperadas 1, obtidas %',v_opp_after-v_opp_before; end if;
  select o.id into v_opp from crm.opportunities o where o.tenant_id=v_tenant and o.title='IMP230 aceite' order by o.created_at desc limit 1;
  if not exists (select 1 from crm.opportunities o join crm.global_pipeline_stages s on s.id=o.current_stage_id where o.id=v_opp and o.tenant_id=v_tenant and s.code='lead' and o.gclid='gclid-imp230' and o.gbraid='gbraid-imp230' and o.wbraid='wbraid-imp230' and o.utm_source='google' and o.utm_medium='cpc' and o.utm_campaign='campanha' and o.utm_content='conteudo' and o.utm_term='termo' and o.crc_owner_profile_id is null and o.sales_owner_profile_id is null) then raise exception 'IMP230_ACCEPT: card/Google/tenant incorretos'; end if;
  if (select count(*) from public.events_normalized where client_id=v_tenant and opportunity_id=v_opp::text and gclid='gclid-imp230') <> 1 then raise exception 'IMP230_ACCEPT: events_normalized nao tem exatamente 1 linha'; end if;
  if has_table_privilege('anon','crm.contacts','INSERT') or has_table_privilege('anon','crm.opportunities','INSERT') or has_function_privilege('anon','public.intake_form_lead(text,uuid,text,text,text,text,text,text,text,text,text,text,text,text)','EXECUTE') then raise exception 'IMP230_ACCEPT: ACL anon aberta'; end if;
  begin perform public.intake_form_lead(v_slug,gen_random_uuid(),'nao deve criar','5511888888888','imp230-invalid@example.invalid'); raise exception 'IMP230_ACCEPT: token invalido aceito'; exception when others then if sqlerrm like 'IMP230_ACCEPT:%' then raise; end if; end;
  raise notice 'IMP230_ACCEPT OK: contato_delta=%, oportunidade_delta=%, dedupe_delta=0, normalized=1, isolamento=1',v_contact_after-v_contact_before,v_opp_after-v_opp_before;
end
$test$;
rollback;
