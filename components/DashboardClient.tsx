'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'
import { resolveClient, getMyClients, amIAgencyUser } from '@/lib/access'
import { type Period, type CustomRange } from '@/lib/utils'
import PeriodSelector from '@/components/PeriodSelector'
import OverviewTab from '@/components/tabs/OverviewTab'
import FunnelTab from '@/components/tabs/FunnelTab'
import ChannelsTab from '@/components/tabs/ChannelsTab'
import MetaTab from '@/components/tabs/MetaTab'
import GoogleTab from '@/components/tabs/GoogleTab'
import LeadsTab from '@/components/tabs/LeadsTab'
import EventsTab from '@/components/tabs/EventsTab'
import DiarioTab from '@/components/tabs/DiarioTab'

type Tab = 'overview' | 'funnel' | 'channels' | 'meta' | 'google' | 'leads' | 'events' | 'diario'

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Visão geral' },
  { id: 'funnel', label: 'Funil' },
  { id: 'channels', label: 'Canais' },
  { id: 'meta', label: 'Meta Ads' },
  { id: 'google', label: 'Google Ads' },
  { id: 'leads', label: 'Leads' },
  { id: 'events', label: 'Eventos' },
  { id: 'diario', label: 'Diário' },
]

// Estados de carregamento da validação de acesso
type Gate = 'checking' | 'ok' | 'denied' | 'noauth'

export default function DashboardClient({ clientSlug }: { clientSlug: string }) {
  const router = useRouter()
  const [gate, setGate] = useState<Gate>('checking')
  const [clientId, setClientId] = useState<string>('')
  const [clientName, setClientName] = useState('')
  const [multiClient, setMultiClient] = useState(false)
  const [ehAgencia, setEhAgencia] = useState(false)

  const [tab, setTab] = useState<Tab>('overview')
  const [period, setPeriod] = useState<Period>('30d')
  const [custom, setCustom] = useState<CustomRange | null>(null)

  useEffect(() => {
    let alive = true
    ;(async () => {
      // 1. precisa estar logado
      const { data: sess } = await supabase.auth.getSession()
      if (!sess.session) { if (alive) setGate('noauth'); return }

      // 2. resolve o slug -> cliente, VALIDANDO acesso (a view é protegida por RLS:
      //    se o usuário não tem acesso a esse slug, retorna null)
      const client = await resolveClient(clientSlug)
      if (!alive) return
      if (!client) { setGate('denied'); return }

      setClientId(client.client_id)
      setClientName(client.client_name)

      // "trocar cliente" depende de ter mais de um cliente. Já o acesso à área
      // interna depende de role = 'agency' no banco — não do número de clientes.
      const [list, agencia] = await Promise.all([getMyClients(), amIAgencyUser()])
      if (!alive) return
      setMultiClient(list.length > 1)
      setEhAgencia(agencia)

      setGate('ok')
    })()
    return () => { alive = false }
  }, [clientSlug])

  async function signOut() {
    await supabase.auth.signOut()
    router.replace('/login')
  }

  function changePeriod(p: Period, c?: CustomRange) {
    setPeriod(p)
    setCustom(c ?? null)
  }

  // redireciona quem não está logado
  useEffect(() => {
    if (gate === 'noauth') router.replace('/login')
  }, [gate, router])

  // Esta rota é client component, então o título vem daqui em vez de metadata.
  useEffect(() => {
    if (gate !== 'ok') return
    const aba = TABS.find((t) => t.id === tab)?.label ?? 'Painel'
    document.title = clientName
      ? `${aba} · ${clientName} · ImpulsHub`
      : `${aba} · ImpulsHub`
  }, [gate, tab, clientName])

  if (gate === 'checking' || gate === 'noauth') {
    return <div className="state"><div className="spinner" />Carregando…</div>
  }

  if (gate === 'denied') {
    return (
      <div className="access-denied">
        <div className="access-denied-card">
          <h2>Acesso não autorizado</h2>
          <p>Você não tem permissão para ver este cliente, ou o endereço está incorreto.</p>
          <button className="btn-primary" onClick={() => router.replace('/clientes')}>Ver meus clientes</button>
        </div>
      </div>
    )
  }

  const ROTULO_ANTERIOR: Record<string, string> = {
    '7d': '7d ant.', '15d': '15d ant.', '30d': '30d ant.', '90d': '90d ant.',
  }
  const periodLabel = ROTULO_ANTERIOR[period] ?? 'per. ant.'
  const showPeriod = ['overview', 'funnel', 'channels', 'meta', 'google', 'leads', 'diario'].includes(tab)

  return (
    <>
      <div className="topbar">
        <div className="wrap topbar-inner">
          <div className="brand">
            <img className="brand-logo" src="/logo-impuls.png" alt="Impuls" />
            <span className="brand-name">ImpulsHub</span>
            {clientName && <span className="brand-client">{clientName}</span>}
          </div>
          <div className="topbar-right">
            {ehAgencia && <button className="signout-link" onClick={() => router.push('/agencia')}>Agência</button>}
            {multiClient && <button className="signout-link" onClick={() => router.replace('/clientes')}>Trocar cliente</button>}
            <button className="signout" onClick={signOut}>Sair</button>
          </div>
        </div>
      </div>

      <div className="wrap">
        <div className="pagehead tight">
          <div>
            <h1>{TABS.find((t) => t.id === tab)?.label}</h1>
            <div className="sub">Resultados reais do seu marketing, do CRM à mídia</div>
          </div>
          {showPeriod && <PeriodSelector period={period} custom={custom} onChange={changePeriod} />}
        </div>

        <div className="tabs">
          {TABS.map((t) => (
            <button key={t.id} className={`tab ${tab === t.id ? 'active' : ''}`} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </div>

        {tab === 'overview' && <OverviewTab clientId={clientId} period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'funnel' && <FunnelTab clientId={clientId} period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'channels' && <ChannelsTab clientId={clientId} period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'meta' && <MetaTab clientId={clientId} period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'google' && <GoogleTab clientId={clientId} period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'leads' && <LeadsTab clientId={clientId} period={period} custom={custom} />}
        {tab === 'events' && <EventsTab clientId={clientId} />}
        {tab === 'diario' && <DiarioTab clientId={clientId} period={period} custom={custom} />}
      </div>

      <footer>ImpulsHub · Dados atualizados diariamente · Fuso America/São_Paulo</footer>
    </>
  )
}
