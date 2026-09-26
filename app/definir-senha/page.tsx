'use client'

import { FormEvent, useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { supabase } from '@/lib/supabase'

const MIN_PASSWORD_LENGTH = 8

export default function SetPasswordPage() {
  const router = useRouter()
  const [password, setPassword] = useState('')
  const [confirmation, setConfirmation] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    let active = true

    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!active) return
      if (!session) {
        router.replace('/login')
        return
      }
      setLoading(false)
    })

    return () => {
      active = false
    }
  }, [router])

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')

    if (password.length < MIN_PASSWORD_LENGTH) {
      setError(`A senha deve ter pelo menos ${MIN_PASSWORD_LENGTH} caracteres.`)
      return
    }

    if (password !== confirmation) {
      setError('As senhas não coincidem.')
      return
    }

    setSaving(true)
    const { error: updateError } = await supabase.auth.updateUser({ password })
    setSaving(false)

    if (updateError) {
      setError('Não foi possível definir a senha. Tente novamente.')
      return
    }

    router.replace('/dashboard')
  }

  if (loading) {
    return <div className="state">Verificando seu convite…</div>
  }

  return (
    <div className="login-page">
      <main className="login-card">
        <img className="login-logo" src="/logo-impuls.png" alt="Impuls" />
        <h1>Defina sua senha</h1>
        <p className="sub">Crie uma senha para acessar o painel Impuls.</p>

        {error && <div className="login-error" role="alert">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div className="field">
            <label htmlFor="password">Nova senha</label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              autoComplete="new-password"
              minLength={MIN_PASSWORD_LENGTH}
              required
              disabled={saving}
            />
          </div>
          <div className="field">
            <label htmlFor="confirmation">Confirme sua senha</label>
            <input
              id="confirmation"
              type="password"
              value={confirmation}
              onChange={(event) => setConfirmation(event.target.value)}
              autoComplete="new-password"
              minLength={MIN_PASSWORD_LENGTH}
              required
              disabled={saving}
            />
          </div>
          <button className="btn" type="submit" disabled={saving}>
            {saving ? 'Salvando…' : 'Continuar'}
          </button>
        </form>
      </main>
    </div>
  )
}
