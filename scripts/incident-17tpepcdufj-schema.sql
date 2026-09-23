begin;
select substring(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure) from position('if v_oportunidade_id' in pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) for 6000) as parser_section;
rollback;
