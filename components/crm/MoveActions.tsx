'use client'

import { useState } from 'react'
import {
  moveStage, registerWon, registerLost, fetchCard,
  type BoardCount, type CrmCard, type LossReason, type StageCode,
} from '@/lib/crm'

// As ações de escrita do card. Só renderiza para quem pode escrever — o
// `viewer` enxerga o card inteiro e não encontra botão, em vez de clicar e
// tomar um erro de trigger.
//
// Ganho e Perdido não são "mover para a coluna": carregam observação, valor e
// motivo canônico, e são terminais. Por isso têm caminho próprio.

type Modo = 'idle' | 'mover' | 'ganho' | 'perdido'

export default function MoveActions({
  card, stages, lossReasons, onChanged, onAviso,
}: {
  card: CrmCard
  stages: BoardCount[]
  lossReasons: LossReason[]
  onChanged: (card: CrmCard) => void
  onAviso: (msg: string) => void
}) {
  const [modo, setModo] = useState<Modo>('idle')
  const [salvando, setSalvando] = useState(false)
  const [erroLocal, setErroLocal] = useState('')

  const [destino, setDestino] = useState<StageCode | ''>('')
  const [motivo, setMotivo] = useState('')
  const [evidencia, setEvidencia] = useState('')
  const [valor, setValor] = useState('')
  const [lossCode, setLossCode] = useState('')
  const [nota, setNota] = useState('')

  // Ganho e Perdido são terminais: nenhuma ação sai deles. Reabrir card
  // fechado está fora deste sprint.
  if (card.is_terminal) {
    return (
      <div className="crm-terminal-note">
        Card fechado como <b>{card.stage_label}</b>. Não há ações disponíveis.
      </div>
    )
  }

  const naoTerminais = stages.filter((s) => !s.is_terminal && s.stage_code !== card.stage_code)
  const destinoStage = naoTerminais.find((s) => s.stage_code === destino) ?? null
  const ehRegressao = !!destinoStage && destinoStage.stage_position < card.stage_position
  const motivoObrigatorio = lossReasons.find((r) => r.code === lossCode)?.requires_note ?? false

  function limpa() {
    setModo('idle'); setErroLocal('')
    setDestino(''); setMotivo(''); setEvidencia(''); setValor(''); setLossCode(''); setNota('')
  }

  // Todo resultado vem do banco: substituímos o card pelo retorno da RPC em
  // vez de montar na mão o estado novo. Em conflito de versão, recarregamos.
  async function aplica(chamada: Promise<{ card: CrmCard | null; erro: { codigo: string; mensagem: string } | null }>) {
    setSalvando(true)
    const { card: novo, erro } = await chamada

    if (erro) {
      setSalvando(false)
      setErroLocal(erro.mensagem)
      if (erro.codigo === 'CRM_STAGE_CONFLICT') {
        // Recarrega o card e MANTÉM o formulário aberto: o `card` novo chega
        // por prop com a versão atualizada, então o próximo clique funciona.
        // Fechar aqui apagaria o que a pessoa digitou e a mensagem junto.
        const atual = await fetchCard(card.client_id, card.opportunity_id)
        if (atual) onChanged(atual)
        onAviso(erro.mensagem)
      }
      return
    }

    setSalvando(false)
    if (novo) onChanged(novo)
    limpa()
    onAviso('')
  }

  function mover() {
    if (!destino) { setErroLocal('Escolha a etapa de destino.'); return }
    if (ehRegressao && !motivo.trim()) {
      setErroLocal('Voltar um card para uma etapa anterior exige um motivo.')
      return
    }
    aplica(moveStage(card.opportunity_id, destino, card.stage_version, motivo))
  }

  function ganhar() {
    if (!evidencia.trim()) { setErroLocal('A observação é obrigatória.'); return }
    aplica(registerWon(card.opportunity_id, evidencia, card.stage_version, valor))
  }

  function perder() {
    if (!lossCode) { setErroLocal('Escolha o motivo da perda.'); return }
    if (motivoObrigatorio && !nota.trim()) { setErroLocal('O motivo "Outro" exige uma observação.'); return }
    aplica(registerLost(card.opportunity_id, lossCode, card.stage_version, nota))
  }

  return (
    <div className="crm-actions">
      {modo === 'idle' && (
        <div className="crm-actions-row">
          <button className="crm-btn" onClick={() => setModo('mover')}>Mover etapa</button>
          <button className="crm-btn crm-btn-win" onClick={() => setModo('ganho')}>Registrar ganho</button>
          <button className="crm-btn crm-btn-lost" onClick={() => setModo('perdido')}>Registrar perda</button>
        </div>
      )}

      {modo === 'mover' && (
        <div className="crm-form">
          <label>Mover para</label>
          <select
            className="select-native"
            value={destino}
            onChange={(e) => { setDestino(e.target.value as StageCode); setErroLocal('') }}
          >
            <option value="">Escolha a etapa…</option>
            {naoTerminais.map((s) => (
              <option key={s.stage_code} value={s.stage_code}>{s.stage_label}</option>
            ))}
          </select>

          {ehRegressao && (
            <>
              <label>Motivo de voltar a etapa</label>
              <textarea
                rows={2}
                value={motivo}
                onChange={(e) => setMotivo(e.target.value)}
                placeholder="Por que este card voltou?"
              />
              <p className="crm-hint">
                O marco anterior não é apagado — o histórico registra a volta.
              </p>
            </>
          )}

          <Rodape salvando={salvando} erro={erroLocal} onOk={mover} onCancel={limpa} rotulo="Mover" />
        </div>
      )}

      {modo === 'ganho' && (
        <div className="crm-form">
          <label>Observação <span className="crm-req">obrigatória</span></label>
          <textarea
            rows={2}
            value={evidencia}
            onChange={(e) => { setEvidencia(e.target.value); setErroLocal('') }}
            placeholder="O que foi fechado?"
          />

          <label>Valor (R$)</label>
          <input
            type="text"
            inputMode="decimal"
            value={valor}
            onChange={(e) => setValor(e.target.value)}
            placeholder="Deixe em branco se ainda não souber"
          />
          <p className="crm-hint">
            Em branco, o valor fica <b>pendente</b> — não vira zero. Um ganho de R$ 0,00
            contaria como venda sem receita no dashboard.
          </p>

          <Rodape salvando={salvando} erro={erroLocal} onOk={ganhar} onCancel={limpa} rotulo="Registrar ganho" />
        </div>
      )}

      {modo === 'perdido' && (
        <div className="crm-form">
          <label>Motivo da perda</label>
          <select
            className="select-native"
            value={lossCode}
            onChange={(e) => { setLossCode(e.target.value); setErroLocal('') }}
          >
            <option value="">Escolha o motivo…</option>
            {lossReasons.map((r) => (
              <option key={r.code} value={r.code}>{r.label}</option>
            ))}
          </select>

          {motivoObrigatorio && (
            <>
              <label>Observação <span className="crm-req">obrigatória</span></label>
              <textarea
                rows={2}
                value={nota}
                onChange={(e) => { setNota(e.target.value); setErroLocal('') }}
                placeholder="Descreva o motivo"
              />
            </>
          )}

          <p className="crm-hint">Perda não registra valor — só o motivo.</p>

          <Rodape salvando={salvando} erro={erroLocal} onOk={perder} onCancel={limpa} rotulo="Registrar perda" />
        </div>
      )}
    </div>
  )
}

function Rodape({
  salvando, erro, onOk, onCancel, rotulo,
}: {
  salvando: boolean; erro: string; onOk: () => void; onCancel: () => void; rotulo: string
}) {
  return (
    <>
      {erro && <p className="crm-erro">{erro}</p>}
      <div className="crm-actions-row">
        <button className="crm-btn crm-btn-primary" disabled={salvando} onClick={onOk}>
          {salvando ? 'Salvando…' : rotulo}
        </button>
        <button className="crm-btn" disabled={salvando} onClick={onCancel}>Cancelar</button>
      </div>
    </>
  )
}
