'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'
import { getMyClients, type ClientAccess } from '@/lib/access'

export default function ClientesPage() {
  const router = useRouter()
  const [loading, setLoading] = useState(true)
  const [clients, setClients] = useState<ClientAccess[]>([])

  useEffect(() => {
    let alive = true
    ;(async () => {
      const { data: sess } = await supabase.auth.getSession()
      if (!sess.session) { router.replace('/login'); return }

      const list = await getMyClients()
      if (!alive) return
      // se só tem 1 cliente, vai direto pro dashboard dele
      if (list.length === 1) {
        router.replace(`/clientes/${list[0].client_slug}/dashboard`)
        return
      }
      setClients(list)
      setLoading(false)
    })()
    return () => { alive = false }
  }, [router])

  async function signOut() {
    await supabase.auth.signOut()
    router.replace('/login')
  }

  if (loading) return <div className="state"><div className="spinner" />Carregando…</div>

  return (
    <>
      <div className="topbar">
        <div className="wrap topbar-inner">
          <div className="brand">
            <img className="brand-logo" src="/logo-impuls.png" alt="Impuls" />
            <span className="brand-name">ImpulsHub</span>
          </div>
          <div className="topbar-right">
            <button className="signout" onClick={signOut}>Sair</button>
          </div>
        </div>
      </div>

      <div className="wrap">
        <div className="pagehead">
          <div>
            <h1>Seus clientes</h1>
            <div className="sub">Selecione um cliente para ver o painel</div>
          </div>
        </div>

        <div className="client-grid">
          {clients.map((c) => (
            <button key={c.client_id} className="client-card" onClick={() => router.push(`/clientes/${c.client_slug}/dashboard`)}>
              <div className="client-card-name">{c.client_name}</div>
              <div className="client-card-slug">{c.client_slug}</div>
              <div className="client-card-go">Abrir painel →</div>
            </button>
          ))}
          {clients.length === 0 && (
            <div className="table-empty">Nenhum cliente disponível para o seu acesso.</div>
          )}
        </div>
      </div>

      <footer>ImpulsHub · Dados atualizados diariamente · Fuso America/São_Paulo</footer>
    </>
  )
}
