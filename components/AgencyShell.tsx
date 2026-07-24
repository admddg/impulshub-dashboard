'use client'

import { useEffect, useState } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import Link from 'next/link'
import { supabase } from '@/lib/supabase'
import { amIAgencyUser } from '@/lib/access'

type Gate = 'checking' | 'ok' | 'denied' | 'noauth'

const NAV: { href: string; label: string; icon: JSX.Element }[] = [
  {
    href: '/agencia', label: 'Overview',
    icon: <><rect x="3" y="3" width="7" height="9" rx="1" /><rect x="14" y="3" width="7" height="5" rx="1" /><rect x="14" y="12" width="7" height="9" rx="1" /><rect x="3" y="16" width="7" height="5" rx="1" /></>,
  },
  {
    href: '/agencia/onboarding', label: 'Onboarding',
    icon: <><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" /><path d="M22 4 12 14.01l-3-3" /></>,
  },
  {
    href: '/agencia/tracking', label: 'Tracking',
    icon: <><path d="M22 12h-4l-3 9L9 3l-3 9H2" /></>,
  },
  {
    href: '/agencia/sync', label: 'Sync',
    icon: <><path d="M23 4v6h-6" /><path d="M1 20v-6h6" /><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" /></>,
  },
]

export default function AgencyShell({ children }: { children: React.ReactNode }) {
  const router = useRouter()
  const pathname = usePathname()
  const [gate, setGate] = useState<Gate>('checking')

  useEffect(() => {
    let alive = true
    ;(async () => {
      const { data: sess } = await supabase.auth.getSession()
      if (!sess.session) { if (alive) setGate('noauth'); return }

      // Quem responde é o banco (role = 'agency'), não o número de clientes.
      const ehAgencia = await amIAgencyUser()
      if (!alive) return
      setGate(ehAgencia ? 'ok' : 'denied')
    })()
    return () => { alive = false }
  }, [])

  useEffect(() => {
    if (gate === 'noauth') router.replace('/login')
  }, [gate, router])

  async function signOut() {
    await supabase.auth.signOut()
    router.replace('/login')
  }

  if (gate === 'checking' || gate === 'noauth') {
    return <div className="state"><div className="spinner" />Carregando…</div>
  }

  if (gate === 'denied') {
    return (
      <div className="access-denied">
        <div className="access-denied-card">
          <h2>Área restrita</h2>
          <p>Esta área é da equipe interna da agência.</p>
          <button className="btn-primary" onClick={() => router.replace('/clientes')}>Ver meus clientes</button>
        </div>
      </div>
    )
  }

  return (
    <div className="ag-shell">
      <aside className="ag-side">
        <div className="ag-brand">
          <img className="ag-brand-logo" src="/logo-impuls-bolinha.png" alt="" />
          <div>
            <div className="ag-brand-name">ImpulsHub</div>
            <div className="ag-brand-sub">Agência</div>
          </div>
        </div>

        <nav className="ag-nav">
          {NAV.map((n) => {
            const ativo = n.href === '/agencia' ? pathname === '/agencia' : pathname.startsWith(n.href)
            return (
              <Link key={n.href} href={n.href} className={`ag-nav-item ${ativo ? 'active' : ''}`}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  {n.icon}
                </svg>
                {n.label}
              </Link>
            )
          })}
        </nav>

        <div className="ag-side-foot">
          <button className="ag-side-link" onClick={() => router.push('/clientes')}>Painéis de cliente</button>
          <button className="ag-side-link" onClick={signOut}>Sair</button>
        </div>
      </aside>

      <main className="ag-main">{children}</main>
    </div>
  )
}
