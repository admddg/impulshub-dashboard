'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'
import { getMyClients } from '@/lib/access'

// Redirecionador inteligente:
// - sem sessão -> /login
// - 1 cliente  -> /clientes/[slug]/dashboard (direto)
// - vários     -> /clientes (seletor)
export default function DashboardRedirect() {
  const router = useRouter()

  useEffect(() => {
    let alive = true
    ;(async () => {
      const { data: sess } = await supabase.auth.getSession()
      if (!sess.session) { router.replace('/login'); return }

      const list = await getMyClients()
      if (!alive) return
      if (list.length === 1) {
        router.replace(`/clientes/${list[0].client_slug}/dashboard`)
      } else {
        router.replace('/clientes')
      }
    })()
    return () => { alive = false }
  }, [router])

  return <div className="state"><div className="spinner" />Redirecionando…</div>
}
