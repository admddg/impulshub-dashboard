'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'

export default function Home() {
  const router = useRouter()

  useEffect(() => {
    // Ao abrir a raiz, checa se já existe sessão e manda pro lugar certo.
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) {
        router.replace('/dashboard')
      } else {
        router.replace('/login')
      }
    })
  }, [router])

  return (
    <div className="state">
      <div className="spinner" />
      Carregando…
    </div>
  )
}
