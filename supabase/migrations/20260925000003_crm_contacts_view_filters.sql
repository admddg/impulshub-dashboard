-- Expoe opened_at e owner_profile_id em v_crm_contacts_v1.
--
-- Sem essas duas colunas, os filtros de criacao e proprietario valiam so no
-- kanban: a visao de lista nao tinha por onde filtrar, e o navegador nao
-- alcanca o schema crm para buscar o dado direto. A tela passou a avisar que o
-- filtro nao se aplica ali -- honesto, mas o certo e nao precisar do aviso.
--
-- A view ja faz o LEFT JOIN LATERAL na oportunidade mais recente do contato.
-- As duas colunas vem desse mesmo join: custo zero, nenhuma juncao nova.
--
-- Colunas entram no FIM da lista de proposito: create or replace view exige que
-- as existentes mantenham nome, tipo e ordem.

set local lock_timeout = '5s';

create or replace view public.v_crm_contacts_v1
with (security_invoker = true) as
 select c.tenant_id as client_id,
    c.id as contact_id,
    c.full_name,
    c.phone_normalized,
    c.email,
    case
      when c.phone_normalized is not null then 'https://wa.me/'::text || c.phone_normalized
      else null::text
    end as whatsapp_url,
    c.status,
    act.last_activity_at,
    coalesce(act.messages_total, 0::bigint) as messages_total,
    o.id as opportunity_id,
    s.code as stage_code,
    s.label as stage_label,
    s."position" as stage_position,
    o.status as opportunity_status,
    (lower(c.full_name) || ' '::text) || coalesce(c.phone_normalized, ''::text) as search_text,
    o.opened_at,
    o.owner_profile_id
   from crm.contacts c
     left join lateral ( select max(a.created_at) as last_activity_at,
            count(*) as messages_total
           from crm.activities a
          where a.tenant_id = c.tenant_id and a.contact_id = c.id) act on true
     left join lateral ( select o2.id,
            o2.status,
            o2.current_stage_id,
            o2.opened_at,
            o2.owner_profile_id
           from crm.opportunities o2
          where o2.tenant_id = c.tenant_id and o2.contact_id = c.id
          order by o2.opened_at desc, o2.created_at desc
         limit 1) o on true
     left join crm.global_pipeline_stages s on s.id = o.current_stage_id;

-- DOWN: reaplicar a definicao anterior, sem as duas ultimas colunas.
