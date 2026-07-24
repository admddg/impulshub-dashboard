'use client'

import { supabase } from '@/lib/supabase'

// ---------------------------------------------------------------------------
// Contrato das RPCs internas da agência.
//
// Ambas devolvem um único jsonb (não TABLE), então os números já chegam como
// number — diferente das views, que mandam numeric como string. O que NÃO muda
// é a semântica do NULL: continua significando "não dá pra calcular" e precisa
// chegar até a tela como "—", nunca como zero.
// ---------------------------------------------------------------------------

export type QualityStatus =
  | 'ok'
  | 'setup_pending'
  | 'investment_incomplete'
  | 'revenue_incomplete'
  | 'acquisition_revenue_incomplete'
  | 'attribution_conflict'

// O bloco `quality` da RPC expõe cinco contadores, mas `quality_status` tem
// seis valores: `revenue_incomplete_clients` soma os dois de receita. Por
// decisão de produto, o card fica agrupado — então o filtro precisa aceitar
// os dois valores, senão o clique traz menos cliente do que o card promete.
export const STATUS_DO_CARD: Record<string, QualityStatus[]> = {
  ok: ['ok'],
  setup_pending: ['setup_pending'],
  investment_incomplete: ['investment_incomplete'],
  revenue_incomplete: ['revenue_incomplete', 'acquisition_revenue_incomplete'],
  attribution_conflict: ['attribution_conflict'],
}

export type AgencyClientRow = {
  id: string
  client_name: string
  client_slug: string
  status: string
  tracking_ready: boolean | null
  sync_ready: boolean | null
  meta_ready: boolean | null
  google_ads_ready: boolean | null
  media_days: number | null
  investment: number | null
  investment_is_complete: boolean | null
  leads: number | null
  paid_attributed_leads: number | null
  meta_ads_leads: number | null
  google_ads_leads: number | null
  unattributed_leads: number | null
  attribution_conflicts: number | null
  primeiras_conversas: number | null
  agendados: number | null
  crm_ganhos: number | null
  acquisition_buying_contacts: number | null
  acquisition_sales: number | null
  cohort_total_sales: number | null
  acquisition_revenue: number | null
  total_cohort_revenue: number | null
  acquisition_revenue_is_complete: boolean | null
  cohort_revenue_is_complete: boolean | null
  closed_sales: number | null
  closed_revenue: number | null
  closed_revenue_is_complete: boolean | null
  cpl_paid: number | null
  cac_acquisition: number | null
  roas_acquisition: number | null
  roas_total_cohort: number | null
  quality_status: QualityStatus
}

export type AgencyPortfolio = {
  clients_count: number
  ready_clients: number
  not_ready_clients: number
  investment: number | null
  investment_is_complete: boolean | null
  leads: number
  paid_attributed_leads: number
  meta_ads_leads: number
  google_ads_leads: number
  unattributed_leads: number
  attribution_conflicts: number
  primeiras_conversas: number
  agendados: number
  crm_ganhos: number
  acquisition_buying_contacts: number
  acquisition_sales: number
  closed_sales: number
  closed_buying_contacts: number
  acquisition_revenue: number | null
  closed_revenue: number | null
  acquisition_revenue_is_complete: boolean | null
  closed_revenue_is_complete: boolean | null
  cpl_paid: number | null
  cac_acquisition: number | null
  roas_acquisition: number | null
}

export type AgencyQuality = {
  ok_clients: number
  setup_pending_clients: number
  investment_incomplete_clients: number
  revenue_incomplete_clients: number
  attribution_conflict_clients: number
}

export type AgencyOverview = {
  portfolio: AgencyPortfolio
  quality: AgencyQuality
  clients: AgencyClientRow[]
}

export type SortBy =
  | 'client_name' | 'investment' | 'leads' | 'agendados'
  | 'acquisition_sales' | 'closed_sales' | 'acquisition_revenue'
  | 'closed_revenue' | 'cpl_paid' | 'cac_acquisition' | 'roas_acquisition'

// A busca e a ordenação vão para o servidor (p_search / p_sort_by). Filtrar no
// navegador exigiria trazer a base inteira — o padrão que já causou truncamento
// silencioso quatro vezes neste projeto.
export async function fetchAgencyOverview(opts: {
  start: string
  end: string
  search?: string | null
  sortBy?: SortBy
  sortDirection?: 'asc' | 'desc'
  includeNotReady?: boolean
}): Promise<{ data: AgencyOverview | null; error: string | null }> {
  const { data, error } = await supabase.rpc('get_internal_agency_overview', {
    p_start_date: opts.start,
    p_end_date: opts.end,
    p_client_ids: null,
    p_include_not_ready: opts.includeNotReady ?? true,
    p_search: opts.search?.trim() || null,
    p_sort_by: opts.sortBy ?? 'investment',
    p_sort_direction: opts.sortDirection ?? 'desc',
  })

  if (error) {
    console.error('[Impuls] agency overview:', error.message)
    return { data: null, error: error.message }
  }
  return { data: (data ?? null) as AgencyOverview | null, error: null }
}

// ---------------------------------------------------------------------------
// Feed operacional — uma RPC, três seções.
// ---------------------------------------------------------------------------

export type OpsSection = 'onboarding' | 'events_tracking' | 'syncs'
export type EventLayer = 'raw' | 'normalized' | 'tracking' | 'n8n_tracking'
export type HealthStatus = 'ok' | 'info' | 'pending' | 'warning' | 'error'

export type OpsRow = {
  event_at: string | null
  event_date: string | null
  event_domain: string | null
  event_group: string | null
  client_id: string | null
  client_name: string | null
  client_slug: string | null
  event_code: string | null
  contact_id: string | null
  contact_name: string | null
  opportunity_id: string | null
  platform: string | null
  route: string | null
  stage: string | null
  source_relation: string | null
  source_id: string | null
  source_status: string | null
  health_status: HealthStatus
  correlation_id: string | null
  workflow_key: string | null
  workflow_name: string | null
  workflow_category: string | null
  n8n_execution_id: string | null
  attempts: number | null
  duration_ms: number | null
  items_processed: number | null
  items_failed: number | null
  summary: string | null
}

export type OpsSummary = {
  total: number
  ok: number
  info: number
  pending: number
  warning: number
  error: number
  last_event_at: string | null
  by_group: Record<string, number>
}

export type OpsPagination = {
  limit: number
  offset: number
  returned: number
  total: number
  has_more: boolean
}

export type OpsFeed = {
  summary: OpsSummary
  pagination: OpsPagination
  rows: OpsRow[]
}

// A camada de tracking sozinha tem ~1.600 linhas em 14 dias. A paginação é
// server-side desde o primeiro commit: p_limit / p_offset, com has_more.
export async function fetchOperationsFeed(opts: {
  section: OpsSection
  eventLayer?: EventLayer | null
  clientId?: string | null
  start: string
  end: string
  status?: HealthStatus | null
  search?: string | null
  limit?: number
  offset?: number
}): Promise<{ data: OpsFeed | null; error: string | null }> {
  const { data, error } = await supabase.rpc('get_internal_operations_feed', {
    p_section: opts.section,
    p_event_layer: opts.eventLayer ?? null,
    p_client_id: opts.clientId ?? null,
    p_start_date: opts.start,
    p_end_date: opts.end,
    p_status: opts.status ?? null,
    p_search: opts.search?.trim() || null,
    p_limit: opts.limit ?? 100,
    p_offset: opts.offset ?? 0,
  })

  if (error) {
    console.error('[Impuls] operations feed:', opts.section, error.message)
    return { data: null, error: error.message }
  }
  return { data: (data ?? null) as OpsFeed | null, error: null }
}

// ---------------------------------------------------------------------------
// Tracking — v_event_tracking_audit (1 linha por evento bruto).
//
// Contrato do banco: overall_status/overall_reason são a VERDADE do status.
// Os indicadores de etapa explicam a jornada, não recalculam o geral. Nada de
// health/SLA/aplicabilidade no frontend — tudo vem pronto.
// ---------------------------------------------------------------------------

export type OverallStatus = 'ok' | 'warning' | 'processing' | 'inconsistent' | 'error'

// Cada job de conversão dentro do jsonb conversion_jobs. Todas as chaves são
// opcionais: um job "pending sem dispatcher" traz muito menos que um "sent".
export type ConversionJob = {
  outbox_id?: string
  normalized_event_id?: string
  platform?: string
  route?: string
  platform_event_name?: string
  status?: string
  audit_status?: string
  reason?: string
  attempts?: number
  http_status?: number
  created_at?: string
  sent_at?: string
  next_attempt_at?: string
  dispatch_workflow_key?: string
  dispatch_workflow_name?: string
  dispatch_execution_id?: string
  dispatch_source_status?: string
  dispatch_status?: string
  last_checkpoint?: string
  dispatch_started_at?: string
  dispatch_finished_at?: string
  dispatch_error_node?: string
  dispatch_error_message?: string
}

export type TrackingRow = {
  raw_event_id: string
  normalized_event_id: string | null
  client_id: string | null
  client_name: string | null
  client_slug: string | null
  contact_id: string | null
  full_name: string | null
  event_code: string | null
  event_datetime: string | null
  received_at: string | null
  raw_audit_status: string | null
  raw_audit_reason: string | null
  normalization_status: string | null
  normalization_audit_status: string | null
  normalization_audit_reason: string | null
  conversion_applicability: string | null
  conversion_jobs_count: number | null
  conversion_summary_status: string | null
  conversion_summary_reason: string | null
  conversion_jobs: ConversionJob[] | null
  inbound_n8n_status: string | null
  inbound_n8n_stage: string | null
  inbound_n8n_error_message: string | null
  dispatch_n8n_status: string | null
  overall_status: OverallStatus
  overall_reason: string | null
}

const TRACKING_COLS =
  'raw_event_id, normalized_event_id, client_id, client_name, client_slug, ' +
  'contact_id, full_name, event_code, event_datetime, received_at, ' +
  'raw_audit_status, raw_audit_reason, normalization_status, ' +
  'normalization_audit_status, normalization_audit_reason, ' +
  'conversion_applicability, conversion_jobs_count, conversion_summary_status, ' +
  'conversion_summary_reason, conversion_jobs, inbound_n8n_status, ' +
  'inbound_n8n_stage, inbound_n8n_error_message, dispatch_n8n_status, ' +
  'overall_status, overall_reason'

// A view tem escopo de cliente (private.user_can_access_client). Paginação
// server-side: a camada de tracking passa de 1.000 linhas com folga.
export async function fetchTracking(opts: {
  start: string
  end: string
  clientId?: string | null
  status?: OverallStatus | null
  search?: string | null
  limit?: number
  offset?: number
}): Promise<{ rows: TrackingRow[]; total: number | null; error: string | null }> {
  const limit = opts.limit ?? 100
  const offset = opts.offset ?? 0

  let q = supabase
    .from('v_event_tracking_audit')
    .select(TRACKING_COLS, { count: 'exact' })
    .gte('received_at', opts.start)
    .lte('received_at', opts.end + 'T23:59:59.999Z')
    .order('received_at', { ascending: false })
    .range(offset, offset + limit - 1)

  if (opts.clientId) q = q.eq('client_id', opts.clientId)
  if (opts.status) q = q.eq('overall_status', opts.status)
  // Busca simples por contato ou evento. ilike no servidor, não no navegador.
  if (opts.search && opts.search.trim()) {
    const s = `%${opts.search.trim()}%`
    q = q.or(`full_name.ilike.${s},event_code.ilike.${s},contact_id.ilike.${s}`)
  }

  const { data, error, count } = await q
  if (error) {
    console.error('[Impuls] tracking audit:', error.message)
    return { rows: [], total: null, error: error.message }
  }
  return { rows: (data ?? []) as unknown as TrackingRow[], total: count ?? null, error: null }
}

// ---------------------------------------------------------------------------
// Sync — v_sync_health (grão fixo: client_id + platform + operation_type,
// 4 linhas por cliente ativo). Não é feed cronológico: é quadro de estado.
// ---------------------------------------------------------------------------

export type SyncHealthStatus =
  | 'ok' | 'error' | 'running' | 'telemetry_not_closed'
  | 'backfill_completed' | 'completed_no_data' | 'not_run'

export type SyncRow = {
  client_id: string
  client_name: string | null
  client_slug: string | null
  platform: string
  operation_type: string
  workflow_key: string | null
  is_enabled: boolean | null
  last_attempt_at: string | null
  last_success_at: string | null
  last_finished_at: string | null
  last_status: string | null
  last_checkpoint: string | null
  last_error_node: string | null
  last_error_message: string | null
  duration_ms: number | null
  items_processed: number | null
  items_failed: number | null
  last_physical_write_at: string | null
  max_data_date: string | null
  rows_written_recently: number | null
  backfill_status: string | null
  backfill_error: string | null
  saved_last_sync_at: string | null
  health_status: SyncHealthStatus
  health_reason: string | null
}

export async function fetchSyncHealth(): Promise<{ rows: SyncRow[]; error: string | null }> {
  const { data, error } = await supabase
    .from('v_sync_health')
    .select('*')
    .order('client_name', { ascending: true })
    .order('platform', { ascending: true })

  if (error) {
    console.error('[Impuls] sync health:', error.message)
    return { rows: [], error: error.message }
  }
  return { rows: (data ?? []) as unknown as SyncRow[], error: null }
}
