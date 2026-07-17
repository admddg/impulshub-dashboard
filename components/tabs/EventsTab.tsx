'use client'

import { useEffect, useState, useCallback } from 'react'
import { supabase } from '@/lib/supabase'

type EventRow = {
  event_id: string; event_datetime_local: string; event_code: string; event_name: string | null
  full_name: string | null; phone: string | null; opportunity_id: string | null
  lead_origem: string | null; lead_entrada: string | null
}

const COLS = 'event_id, event_datetime_local, event_code, event_name, full_name, phone, opportunity_id, lead_origem, lead_entrada'

const EVENT_LABEL: Record<string, string> = {
  lead: 'Novo lead', primeira_conversa: 'Primeira conversa',
  agendado: 'Agendou', ganho: 'Ganho', perdido: 'Perdido',
}

function eventBadge(code: string) {
  switch (code) {
    case 'ganho': return 'scale'; case 'perdido': return 'pause'
    case 'agendado': return 'watch'; default: return 'keep'
  }
}

function fmtHora(iso: string) {
  const d = new Date(iso)
  const h = d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })
  if (d.toDateString() === new Date().toDateString()) return `Hoje ${h}`
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' }) + ' ' + h
}

export default function EventsTab({ clientId }: { clientId: string }) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<EventRow[]>([])
  const [refreshing, setRefreshing] = useState(false)

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('v_crm_events_feed_v2').select(COLS)
      .eq('client_id', clientId)
      .order('event_datetime_local', { ascending: false }).limit(50)
    if (error) console.error('[Impuls] eventos:', error.message)
    setRows((data ?? []) as EventRow[])
    setLoading(false); setRefreshing(false)
  }, [clientId])

  useEffect(() => { load() }, [load])

  if (loading) return <div className="state"><div className="spinner" />Carregando eventos…</div>

  return (
    <>
      <div className="subbar" style={{ justifyContent: 'space-between' }}>
        <span className="subbar-label">Últimos 50 eventos do seu CRM</span>
        <button className="refresh-btn" onClick={() => { setRefreshing(true); load() }} disabled={refreshing}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 12a9 9 0 1 1-2.6-6.4M21 3v6h-6" />
          </svg>
          {refreshing ? 'Atualizando…' : 'Atualizar'}
        </button>
      </div>

      <div className="event-feed">
        {rows.length === 0 && <div className="table-empty">Nenhum evento recente.</div>}
        {rows.map((e) => (
          <div className="event-item" key={e.event_id}>
            <span className="event-dot" style={{ background: e.opportunity_id ? '#5fae95' : '#9aa3ac' }} />
            <div className="event-main">
              <div className="event-name">{e.full_name || 'Contato sem nome'}</div>
              <div className="event-meta">{e.lead_entrada || '—'} · {e.lead_origem || '—'}</div>
            </div>
            <span className={`event-badge ${eventBadge(e.event_code)}`}>
              {e.event_name || EVENT_LABEL[e.event_code] || e.event_code}
            </span>
            <span className="event-time">{fmtHora(e.event_datetime_local)}</span>
          </div>
        ))}
      </div>

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" />
        </svg>
        A lista mostra a atividade mais recente do seu funil, em tempo real.
      </div>
    </>
  )
}
