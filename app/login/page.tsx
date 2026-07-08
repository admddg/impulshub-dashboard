'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'

export default function LoginPage() {
  const router = useRouter()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  async function handleLogin() {
    setError('')
    setLoading(true)

    const { error } = await supabase.auth.signInWithPassword({ email, password })

    setLoading(false)

    if (error) {
      // Mensagem amigável, na voz do produto (não expõe detalhe técnico).
      setError('E-mail ou senha incorretos. Confira e tente de novo.')
      return
    }
    router.replace('/dashboard')
  }

  return (
    <div className="login-page">
      <div className="login-card">
        {/* O logo entra aqui — você vai salvar o arquivo em /public (ver guia) */}
        <img className="login-logo" src="/logo-impuls.png" alt="Impuls" />
        <h1>Bem-vindo de volta</h1>
        <p className="sub">Acesse o painel de resultados do seu negócio</p>

        {error && <div className="login-error">{error}</div>}

        <div className="field">
          <label>E-mail</label>
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="voce@empresa.com"
            onKeyDown={(e) => e.key === 'Enter' && handleLogin()}
          />
        </div>
        <div className="field">
          <label>Senha</label>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="••••••••"
            onKeyDown={(e) => e.key === 'Enter' && handleLogin()}
          />
        </div>

        <button className="btn" onClick={handleLogin} disabled={loading}>
          {loading ? 'Entrando…' : 'Entrar'}
        </button>
      </div>
    </div>
  )
}
