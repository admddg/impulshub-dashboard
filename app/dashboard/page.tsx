'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'
import { type Period, type CustomRange } from '@/lib/utils'
import PeriodSelector from '@/components/PeriodSelector'
import OverviewTab from '@/components/tabs/OverviewTab'
import FunnelTab from '@/components/tabs/FunnelTab'
import ChannelsTab from '@/components/tabs/ChannelsTab'
import MetaTab from '@/components/tabs/MetaTab'
import GoogleTab from '@/components/tabs/GoogleTab'
import LeadsTab from '@/components/tabs/LeadsTab'
import EventsTab from '@/components/tabs/EventsTab'

type Tab = 'overview' | 'funnel' | 'channels' | 'meta' | 'google' | 'leads' | 'events'

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Visão geral' },
  { id: 'funnel', label: 'Funil' },
  { id: 'channels', label: 'Canais' },
  { id: 'meta', label: 'Meta Ads' },
  { id: 'google', label: 'Google Ads' },
  { id: 'leads', label: 'Leads' },
  { id: 'events', label: 'Eventos' },
]

export default function DashboardPage() {
  const router = useRouter()
  const [tab, setTab] = useState<Tab>('overview')
  const [period, setPeriod] = useState<Period>('7d')
  const [custom, setCustom] = useState<CustomRange | null>(null)
  const [clientName, setClientName] = useState('')
  const [ready, setReady] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      if (!data.session) { router.replace('/login'); return }
      supabase.from('v_client_profile_safe').select('client_name').limit(1).single()
        .then(({ data: p }) => { if (p?.client_name) setClientName(p.client_name) })
      setReady(true)
    })
  }, [router])

  async function signOut() {
    await supabase.auth.signOut()
    router.replace('/login')
  }

  function changePeriod(p: Period, c?: CustomRange) {
    setPeriod(p)
    setCustom(c ?? null)
  }

  const periodLabel = period === '7d' ? '7d ant.' : period === '30d' ? '30d ant.' : 'per. ant.'

  // abas com filtro de período (Leads e Eventos não usam)
  const showPeriod = ['overview', 'funnel', 'channels', 'meta', 'google', 'leads'].includes(tab)

  if (!ready) return <div className="state"><div className="spinner" />Carregando…</div>

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

        {tab === 'overview' && <OverviewTab period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'funnel' && <FunnelTab period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'channels' && <ChannelsTab period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'meta' && <MetaTab period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'google' && <GoogleTab period={period} periodLabel={periodLabel} custom={custom} />}
        {tab === 'leads' && <LeadsTab period={period} custom={custom} />}
        {tab === 'events' && <EventsTab />}
      </div>

      <footer>ImpulsHub · Dados atualizados diariamente · Fuso America/São_Paulo</footer>
    </>
  )
}
