'use client'

import { useEffect, useState, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import { channelBucket, channelColor, entradaBucket } from '@/lib/utils'

type EventRow = {
  event_id: string
  event_datetime: string
  event_code: string
  full_name: string | null
  phone: string | null
  lead_entrada: string | null
  channel_source: string | null
}

const EVENT_LABEL: Record<string, string> = {
  lead: 'Novo lead',
  primeira_conversa: 'Primeira conversa',
  agendado: 'Agendou',
  ganho: 'Ganho',
  perdido: 'Perdido',
}

function eventBadge(code: string) {
  switch (code) {
    case 'ganho': return 'scale'
    case 'perdido': return 'pause'
    case 'agendado': return 'watch'
    default: return 'keep'
  }
}

function fmtHora(iso: string) {
  const d = new Date(iso)
  const hoje = new Date()
  const mesmoDia = d.toDateString() === hoje.toDateString()
  if (mesmoDia) return `Hoje ${d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}`
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' }) + ' ' + d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })
}

export default function EventsTab() {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<EventRow[]>([])
  const [refreshing, setRefreshing] = useState(false)

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('v_client_recent_events')
      .select('event_id, event_datetime, event_code, full_name, phone, lead_entrada, channel_source')
      .order('event_datetime', { ascending: false })
      .limit(50)
    if (error) console.error('Erro eventos:', error.message)
    setRows((data ?? []) as EventRow[])
    setLoading(false)
    setRefreshing(false)
  }, [])

  useEffect(() => { load() }, [load])

  function refresh() { setRefreshing(true); load() }

  if (loading) return <div className="state"><div className="spinner" />Carregando eventos…</div>

  return (
    <>
      <div className="subbar" style={{ justifyContent: 'space-between' }}>
        <span className="subbar-label">Últimos 50 eventos do seu CRM</span>
        <button className="refresh-btn" onClick={refresh} disabled={refreshing}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 12a9 9 0 1 1-2.6-6.4M21 3v6h-6" /></svg>
          {refreshing ? 'Atualizando…' : 'Atualizar'}
        </button>
      </div>

      <div className="event-feed">
        {rows.length === 0 && <div className="table-empty">Nenhum evento recente.</div>}
        {rows.map((e) => (
          <div className="event-item" key={e.event_id}>
            <span className="event-dot" style={{ background: channelColor(e.channel_source) }} />
            <div className="event-main">
              <div className="event-name">{e.full_name || 'Contato sem nome'}</div>
              <div className="event-meta">{entradaBucket(e.lead_entrada)} · {channelBucket(e.channel_source)}</div>
            </div>
            <span className={`event-badge ${eventBadge(e.event_code)}`}>{EVENT_LABEL[e.event_code] ?? e.event_code}</span>
            <span className="event-time">{fmtHora(e.event_datetime)}</span>
          </div>
        ))}
      </div>

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        A lista mostra a atividade mais recente do seu funil. Clique em Atualizar para ver os eventos mais novos.
      </div>
    </>
  )
}
