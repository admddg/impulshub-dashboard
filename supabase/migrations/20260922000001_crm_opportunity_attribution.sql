-- IMP-204: atribuicao de midia como coluna consultavel na oportunidade.
--
-- A primeira versao do parser guardava a atribuicao dentro de
-- crm.opportunity_milestones.evidence, um campo de texto livre. Isso torna o dado
-- impossivel de consultar com seguranca e quebrou o contrato do IMP-205, que precisa
-- ler ctwa_clid para alimentar public.events_normalized e a Conversions API.
--
-- meta_ad_id vem de contextInfo.externalAdReply.sourceID. Nos dados reais de producao,
-- 270 de 270 ocorrencias casaram com public.meta_ads_daily.ad_id, o que liga cada lead
-- de WhatsApp ao anuncio, campanha, conjunto e criativo que o gerou -- sem depender do
-- retorno da Conversions API.

set local lock_timeout = '5s';

alter table crm.opportunities
  add column ctwa_clid                     text,
  add column conversion_source             text,
  add column meta_ad_id                    text,
  add column source_url                    text,
  add column ad_title                      text,
  add column entry_point_conversion_source text;

comment on column crm.opportunities.ctwa_clid is
  'Click ID do click-to-WhatsApp, decodificado de contextInfo.conversionData. Alimenta events_normalized.ctwa_clid e a Conversions API.';

comment on column crm.opportunities.meta_ad_id is
  'externalAdReply.sourceID. Junta com public.meta_ads_daily.ad_id.';

create index opportunities_meta_ad_idx
  on crm.opportunities (tenant_id, meta_ad_id)
  where meta_ad_id is not null;

create index opportunities_ctwa_idx
  on crm.opportunities (tenant_id, ctwa_clid)
  where ctwa_clid is not null;
