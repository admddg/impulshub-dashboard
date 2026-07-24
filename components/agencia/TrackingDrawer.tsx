'use client'

import { useEffect } from 'react'
import type { TrackingRow, ConversionJob } from '@/lib/agency'
import { quando, TRACO } from '@/components/agencia/format'

// Traduções de status técnico → português. O código original SEMPRE aparece
// junto (entre parênteses), então a leitura amigável nunca esconde a verdade
// técnica de quem for depurar no n8n.
const ROTULO_CONVERSAO: Record<string, string> = {
  sent: 'Enviada e aceita',
  failed: 'Rejeitada pela plataforma',
  pending: 'Aguardando envio',
  skipped: 'Não enviada',
  not_applicable: 'Não se aplica',
  routing_not_recorded: 'Roteamento não registrado',
  stuck: 'Travada',
}

const ROTULO_DISPATCH: Record<string, string> = {
  ok: 'Concluído',
  dispatcher_not_started: 'Dispatcher não iniciou',
  not_closed: 'Log não encerrado',
  workflow_log_missing: 'Log não encontrado',
  running: 'Em execução',
}

function Etapa({ titulo, status, rotulos, reason }: {
  titulo: string
  status: string | null
  rotulos?: Record<string, string>
  reason?: string | null
}) {
  const amigavel = status && rotulos?.[status] ? rotulos[status] : null
  return (
    <div className="ag-drawer-step">
      <div className="ag-drawer-step-title">{titulo}</div>
      <div className="ag-drawer-step-val">
        {status
          ? <>{amigavel ?? status}{amigavel && <span className="ag-drawer-code"> ({status})</span>}</>
          : <span className="cell-muted">{TRACO}</span>}
      </div>
      {reason && <div className="ag-drawer-step-reason">{reason}</div>}
    </div>
  )
}

function Job({ job }: { job: ConversionJob }) {
  const st = job.status ?? job.audit_status ?? ''
  const rejeitado = st === 'failed'
  const n8nOk = job.dispatch_source_status === 'success' || job.dispatch_status === 'ok'

  return (
    <div className={`ag-job ${rejeitado ? 'is-failed' : ''}`}>
      <div className="ag-job-head">
        <span className="ag-job-platform">{job.platform ?? TRACO}{job.route ? ` · ${job.route}` : ''}</span>
        <span className={`ag-health h-${rejeitado ? 'error' : st === 'sent' ? 'ok' : st === 'pending' ? 'pending' : 'info'}`}>
          {ROTULO_CONVERSAO[st] ?? st ?? TRACO}
        </span>
      </div>

      {/* A distinção que o banco pediu para destacar: resultado da plataforma
          separado do resultado técnico do n8n. */}
      <div className="ag-job-split">
        <div>
          <span className="ag-job-k">Conversão</span>
          <span className="ag-job-v">
            {rejeitado
              ? `Rejeitada — ${job.reason ?? 'motivo não informado'}`
              : st === 'sent' ? 'Aceita pela plataforma'
              : ROTULO_CONVERSAO[st] ?? st ?? TRACO}
          </span>
        </div>
        <div>
          <span className="ag-job-k">n8n</span>
          <span className="ag-job-v">
            {n8nOk ? 'OK — execução concluída' : (ROTULO_DISPATCH[job.dispatch_status ?? ''] ?? job.dispatch_status ?? TRACO)}
          </span>
        </div>
      </div>

      <div className="ag-job-grid">
        {job.platform_event_name && <div><span>Evento na plataforma</span><b>{job.platform_event_name}</b></div>}
        {job.attempts !== undefined && <div><span>Tentativas</span><b>{job.attempts}</b></div>}
        {job.http_status !== undefined && <div><span>HTTP</span><b>{job.http_status}</b></div>}
        {job.last_checkpoint && <div><span>Checkpoint</span><b>{job.last_checkpoint}</b></div>}
        {job.created_at && <div><span>Criado</span><b>{quando(job.created_at)}</b></div>}
        {job.sent_at && <div><span>Enviado</span><b>{quando(job.sent_at)}</b></div>}
        {job.next_attempt_at && <div><span>Próx. tentativa</span><b>{quando(job.next_attempt_at)}</b></div>}
        {job.dispatch_execution_id && <div><span>Execução n8n</span><b>{job.dispatch_execution_id}</b></div>}
      </div>

      {job.dispatch_error_message && (
        <div className="ag-job-err">{job.dispatch_error_message}</div>
      )}
    </div>
  )
}

export default function TrackingDrawer({ row, onClose }: { row: TrackingRow; onClose: () => void }) {
  // Fecha no ESC — atalho esperado em qualquer painel lateral.
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', h)
    return () => window.removeEventListener('keydown', h)
  }, [onClose])

  const jobs = row.conversion_jobs ?? []

  return (
    <div className="ag-drawer-backdrop" onClick={onClose}>
      <aside className="ag-drawer" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <div className="ag-drawer-top">
          <div>
            <div className="ag-drawer-title">{row.full_name || 'Contato sem nome'}</div>
            <div className="ag-drawer-sub">
              {row.event_code ?? TRACO} · {row.client_name ?? TRACO} · {quando(row.received_at)}
            </div>
          </div>
          <button className="ag-drawer-close" onClick={onClose} aria-label="Fechar">×</button>
        </div>

        <div className={`ag-drawer-overall h-${row.overall_status}`}>
          <span className="ag-drawer-overall-badge">{ROTULO_OVERALL[row.overall_status] ?? row.overall_status}</span>
          {row.overall_reason && <span className="ag-drawer-overall-reason">{row.overall_reason}</span>}
        </div>

        <div className="ag-drawer-section">Jornada do evento</div>
        <div className="ag-drawer-steps">
          <Etapa titulo="Recebido" status={row.raw_audit_status} reason={row.raw_audit_reason} />
          <Etapa titulo="Normalizado" status={row.normalization_audit_status ?? row.normalization_status} reason={row.normalization_audit_reason} />
          <Etapa titulo="Roteado" status={row.conversion_applicability} />
          <Etapa titulo="Conversão" status={row.conversion_summary_status} reason={row.conversion_summary_reason} />
          <Etapa titulo="Entrada (n8n)" status={row.inbound_n8n_status} reason={row.inbound_n8n_stage ? `Parou em: ${row.inbound_n8n_stage}` : null} />
        </div>

        <div className="ag-drawer-section">
          Envios de conversão {jobs.length > 0 && <span className="ag-drawer-count">{jobs.length}</span>}
        </div>
        {jobs.length === 0 ? (
          <div className="ag-drawer-empty">
            Nenhum job de conversão para este evento
            {row.conversion_applicability === 'not_applicable' ? ' — evento não requer envio a plataforma.' : '.'}
          </div>
        ) : (
          <div className="ag-jobs">{jobs.map((j, i) => <Job key={j.outbox_id ?? i} job={j} />)}</div>
        )}
      </aside>
    </div>
  )
}

const ROTULO_OVERALL: Record<string, string> = {
  ok: 'OK', warning: 'Atenção', processing: 'Em andamento',
  inconsistent: 'Inconsistente', error: 'Erro',
}
