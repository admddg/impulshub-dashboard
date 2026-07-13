'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'
import { getMyClients } from '@/lib/access'
import { int } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'

type Gate = 'checking' | 'ok' | 'denied' | 'noauth'

type HealthRow = {
  key: string
  workflow_key: string; workflow_name: string; workflow_category: string; client_name: string
  total: number; success: number; error: number; partial: number
  durSum: number; durCount: number; lastExec: string
}

type ExecRow = {
  client_id: string
  workflow_key: string; workflow_name: string; workflow_category: string
  status: string; stage: string | null
  started_at: string; finished_at: string | null; duration_ms: number | null
  items_processed: number | null; items_failed: number | null
}

const CATEGORY_LABEL: Record<string, string> = {
  onboarding: 'Onboarding', events: 'Eventos', dispatch: 'Dispatch',
  media_sync: 'Sync de mídia', backfill: 'Backfill', other: 'Outro',
}

const STATUS_LABEL: Record<string, string> = {
  success: 'Sucesso', error: 'Erro', partial: 'Parcial', running: 'Rodando', skipped: 'Pulado',
}

function fmtDuration(ms: number | null) {
  if (ms == null) return '—'
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  const m = Math.floor(ms / 60000)
  const s = Math.round((ms % 60000) / 1000)
  return `${m}m ${s}s`
}

function fmtWhen(iso: string) {
  const d = new Date(iso)
  const hoje = new Date()
  const mesmoDia = d.toDateString() === hoje.toDateString()
  const hora = d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })
  if (mesmoDia) return `Hoje ${hora}`
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' }) + ' ' + hora
}

export default function OperacaoPage() {
  const router = useRouter()
  const [gate, setGate] = useState<Gate>('checking')
  const [loading, setLoading] = useState(true)
  const [health, setHealth] = useState<HealthRow[]>([])
  const [execs, setExecs] = useState<ExecRow[]>([])
  const [clientNames, setClientNames] = useState<Record<string, string>>({})

  useEffect(() => {
    let alive = true
    ;(async () => {
      const { data: sess } = await supabase.auth.getSession()
      if (!sess.session) { setGate('noauth'); return }

      const clients = await getMyClients()
      if (!alive) return
      if (clients.length <= 1) { setGate('denied'); return }

      const nameMap: Record<string, string> = {}
      for (const c of clients) nameMap[c.client_id] = c.client_name
      setClientNames(nameMap)
      setGate('ok')

      const fourteenDaysAgo = new Date()
      fourteenDaysAgo.setDate(fourteenDaysAgo.getDate() - 13)
      const sinceISO = fourteenDaysAgo.toISOString().slice(0, 10)

      const [healthRes, execRes] = await Promise.all([
        supabase.from('v_workflow_health_daily')
          .select('day, workflow_key, workflow_name, workflow_category, client_id, client_name, total_executions, success_count, error_count, partial_count, avg_duration_ms, last_execution_at')
          .gte('day', sinceISO),
        supabase.from('v_client_workflow_health')
          .select('client_id, workflow_key, workflow_name, workflow_category, status, stage, started_at, finished_at, duration_ms, items_processed, items_failed')
          .order('started_at', { ascending: false })
          .limit(50),
      ])

      if (!alive) return

      if (healthRes.error) console.error('Erro em v_workflow_health_daily:', healthRes.error.message)
      if (execRes.error) console.error('Erro em v_client_workflow_health:', execRes.error.message)

      // agrega por workflow + cliente (soma os dias dentro da janela)
      const map = new Map<string, HealthRow>()
      for (const r of (healthRes.data ?? []) as any[]) {
        const key = `${r.workflow_key}|${r.client_id}`
        const acc = map.get(key) ?? {
          key, workflow_key: r.workflow_key, workflow_name: r.workflow_name,
          workflow_category: r.workflow_category, client_name: r.client_name ?? '—',
          total: 0, success: 0, error: 0, partial: 0, durSum: 0, durCount: 0, lastExec: r.last_execution_at,
        }
        acc.total += Number(r.total_executions) || 0
        acc.success += Number(r.success_count) || 0
        acc.error += Number(r.error_count) || 0
        acc.partial += Number(r.partial_count) || 0
        if (r.avg_duration_ms != null) { acc.durSum += Number(r.avg_duration_ms); acc.durCount += 1 }
        if (!acc.lastExec || r.last_execution_at > acc.lastExec) acc.lastExec = r.last_execution_at
        map.set(key, acc)
      }
      setHealth([...map.values()])
      setExecs((execRes.data ?? []) as ExecRow[])
      setLoading(false)
    })()
    return () => { alive = false }
  }, [])

  useEffect(() => {
    if (gate === 'noauth') router.replace('/login')
  }, [gate, router])

  if (gate === 'checking' || gate === 'noauth') {
    return <div className="state"><div className="spinner" />Carregando…</div>
  }

  if (gate === 'denied') {
    return (
      <div className="access-denied">
        <div className="access-denied-card">
          <h2>Acesso não autorizado</h2>
          <p>Esta área é só para a equipe da agência.</p>
          <button className="btn-primary" onClick={() => router.replace('/clientes')}>Voltar para meus clientes</button>
        </div>
      </div>
    )
  }

  const healthCols: Column<HealthRow>[] = [
    { key: 'workflow_name', header: 'Workflow', render: (r) => <span className="cell-strong cell-name" title={r.workflow_name}>{r.workflow_key} · {r.workflow_name}</span>, sortValue: (r) => r.workflow_key, width: 220 },
    { key: 'client_name', header: 'Cliente', render: (r) => r.client_name || <span className="cell-muted">—</span>, sortValue: (r) => r.client_name },
    { key: 'category', header: 'Categoria', render: (r) => <span className="cell-muted">{CATEGORY_LABEL[r.workflow_category] ?? r.workflow_category}</span> },
    { key: 'total', header: 'Execuções', align: 'right', render: (r) => int(r.total), sortValue: (r) => r.total },
    { key: 'success', header: 'Sucesso', align: 'right', render: (r) => <span className="wf-num-success">{int(r.success)}</span>, sortValue: (r) => r.success },
    { key: 'error', header: 'Erro', align: 'right', render: (r) => r.error > 0 ? <span className="wf-num-error">{int(r.error)}</span> : <span className="cell-muted">0</span>, sortValue: (r) => r.error },
    { key: 'partial', header: 'Parcial', align: 'right', render: (r) => r.partial > 0 ? <span className="wf-num-partial">{int(r.partial)}</span> : <span className="cell-muted">0</span>, sortValue: (r) => r.partial },
    { key: 'dur', header: 'Duração média', align: 'right', render: (r) => r.durCount > 0 ? fmtDuration(r.durSum / r.durCount) : '—', sortValue: (r) => r.durCount > 0 ? r.durSum / r.durCount : 0 },
    { key: 'last', header: 'Última execução', align: 'right', render: (r) => r.lastExec ? <span className="cell-muted">{fmtWhen(r.lastExec)}</span> : '—', sortValue: (r) => r.lastExec ?? '' },
  ]

  return (
    <>
      <div className="topbar">
        <div className="wrap topbar-inner">
          <div className="brand">
            <img className="brand-logo" src="/logo-impuls.png" alt="Impuls" />
            <span className="brand-name">ImpulsHub</span>
            <span className="brand-client">Operação</span>
          </div>
          <div className="topbar-right">
            <button className="signout-link" onClick={() => router.replace('/clientes')}>Meus clientes</button>
            <button className="signout" onClick={async () => { await supabase.auth.signOut(); router.replace('/login') }}>Sair</button>
          </div>
        </div>
      </div>

      <div className="wrap">
        <div className="pagehead">
          <div>
            <h1>Operação</h1>
            <div className="sub">Saúde dos workflows do pipeline — só visível para a equipe da agência</div>
          </div>
        </div>

        {loading ? (
          <div className="state"><div className="spinner" />Carregando…</div>
        ) : (
          <>
            <div className="block-head" style={{ marginBottom: 12 }}>
              <span className="block-title">Saúde por workflow</span>
              <span className="block-sub">Últimos 14 dias · agregado por cliente</span>
            </div>
            <DataTable columns={healthCols} rows={health} initialSort={{ key: 'error', dir: 'desc' }} />

            <div className="block-head" style={{ marginBottom: 12, marginTop: 28 }}>
              <span className="block-title">Últimas execuções</span>
              <span className="block-sub">Feed cronológico, todos os clientes</span>
            </div>
            <div className="event-feed">
              {execs.length === 0 && <div className="table-empty">Nenhuma execução registrada ainda.</div>}
              {execs.map((e, i) => (
                <div className="event-item" key={i}>
                  <span className={`wf-dot wf-dot-${e.status}`} />
                  <div className="event-main">
                    <div className="event-name">{e.workflow_key} · {e.workflow_name}</div>
                    <div className="event-meta">
                      {clientNames[e.client_id] ?? e.client_id}
                      {e.stage ? ` · ${e.stage}` : ''}
                      {e.items_processed != null ? ` · ${int(e.items_processed)} itens` : ''}
                      {e.items_failed ? ` (${int(e.items_failed)} falhas)` : ''}
                    </div>
                  </div>
                  <span className={`wf-status wf-status-${e.status}`}>{STATUS_LABEL[e.status] ?? e.status}</span>
                  <span className="event-time">{fmtDuration(e.duration_ms)} · {fmtWhen(e.started_at)}</span>
                </div>
              ))}
            </div>
          </>
        )}
      </div>

      <footer>ImpulsHub · Operação interna · Fuso America/São_Paulo</footer>
    </>
  )
}
