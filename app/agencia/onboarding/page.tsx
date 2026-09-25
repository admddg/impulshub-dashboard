'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import {
  EMPTY_ONBOARDING_FORM, onboardingPayload, validateOnboarding,
  type OnboardingForm, type OnboardingRole,
} from '@/lib/onboarding'

const inputStyle = { width: '100%', padding: '10px 12px', border: '1px solid var(--line)', borderRadius: 8, background: 'var(--surface)', color: 'var(--ink)', boxSizing: 'border-box' as const }
const gridStyle = { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 14 }

function Field({ label, value, onChange, required = false, type = 'text', placeholder = '' }: { label: string; value: string; onChange: (value: string) => void; required?: boolean; type?: string; placeholder?: string }) {
  return <label style={{ display: 'grid', gap: 6, fontSize: 13, color: 'var(--ink-soft)' }}>
    <span>{label}{required ? ' *' : ''}</span>
    <input style={inputStyle} type={type} value={value} placeholder={placeholder} onChange={(event) => onChange(event.target.value)} />
  </label>
}

export default function OnboardingPage() {
  const [form, setForm] = useState<OnboardingForm>(EMPTY_ONBOARDING_FORM)
  const [errors, setErrors] = useState<string[]>([])
  const [message, setMessage] = useState('')
  const [saving, setSaving] = useState(false)
  const [pendingOnboardings, setPendingOnboardings] = useState<Array<{ id: string; clientName: string; pending: number }>>([])
  const [retryingId, setRetryingId] = useState('')

  async function loadPendingOnboardings() {
    const { data: onboardings } = await supabase
      .from('internal_onboardings')
      .select('id, client_id, created_at')
      .order('created_at', { ascending: false })
      .limit(10)
    const ids = (onboardings ?? []).map((item) => item.id)
    if (!ids.length) { setPendingOnboardings([]); return }
    const [{ data: clients }, { data: users }] = await Promise.all([
      supabase.from('clients_base').select('id, client_name').in('id', onboardings?.map((item) => item.client_id) ?? []),
      supabase.from('internal_onboarding_users').select('onboarding_id').in('onboarding_id', ids).eq('invite_status', 'pending_auth'),
    ])
    const clientNames = new Map((clients ?? []).map((client) => [client.id, client.client_name]))
    const counts = new Map<string, number>()
    for (const user of users ?? []) counts.set(user.onboarding_id, (counts.get(user.onboarding_id) ?? 0) + 1)
    setPendingOnboardings((onboardings ?? []).filter((item) => counts.has(item.id)).map((item) => ({
      id: item.id,
      clientName: clientNames.get(item.client_id) ?? 'Cliente sem nome',
      pending: counts.get(item.id) ?? 0,
    })))
  }

  useEffect(() => { void loadPendingOnboardings() }, [])

  async function retryInvites(onboardingId: string) {
    setRetryingId(onboardingId)
    const { data, error } = await supabase.functions.invoke('invite-internal-onboarding', { body: { onboarding_id: onboardingId } })
    setRetryingId('')
    if (error || !data?.ok) {
      setMessage('Não foi possível reenviar os convites. O cadastro permanece salvo e o erro foi registrado para diagnóstico.')
    } else {
      setMessage(`${data.invited} convite(s) reenviado(s).`)
    }
    await loadPendingOnboardings()
  }
  function set<K extends keyof OnboardingForm>(key: K, value: OnboardingForm[K]) {
    setForm((current) => ({ ...current, [key]: value }))
  }

  function updateUser(index: number, key: 'name' | 'email' | 'role', value: string) {
    set('users', form.users.map((user, currentIndex) => currentIndex === index ? { ...user, [key]: value } as typeof user : user))
  }

  function addUser() { set('users', [...form.users, { name: '', email: '', role: 'atendimento' }]) }
  function removeUser(index: number) { if (form.users.length > 2) set('users', form.users.filter((_, currentIndex) => currentIndex !== index)) }

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setMessage('')
    const validation = validateOnboarding(form)
    setErrors(validation)
    if (validation.length) return
    setSaving(true)
    const { data, error } = await supabase.rpc('create_internal_onboarding', onboardingPayload(form))
    setSaving(false)
    if (error) { setMessage(error.message.includes('FORBIDDEN') ? 'Sua conta não tem permissão para criar onboarding.' : 'Não foi possível salvar o onboarding. Confira os dados e tente novamente.'); return }
    const { data: inviteData, error: inviteError } = await supabase.functions.invoke('invite-internal-onboarding', { body: { onboarding_id: data?.onboarding_id } })
    setErrors([])
    if (inviteError || !inviteData?.ok) {
      setMessage(`Onboarding salvo, mas os convites não foram enviados. ${data?.pending_auth_users ?? 0} usuário(s) continuam pendentes; tente o convite novamente pelo fluxo administrativo.`)
    } else {
      setMessage(`Onboarding salvo. ${inviteData.invited} convite(s) individual(is) enviado(s).`)
    }
    setForm(EMPTY_ONBOARDING_FORM)
  }

  return <div>
    <div className="pagehead tight"><div><h1>Novo onboarding</h1><div className="sub">Um envio cria o cliente, registra os dados legais e prepara as contas individuais.</div></div></div>
    {pendingOnboardings.length > 0 && <section className="block" style={{ padding: 22, marginBottom: 22 }}>
      <div className="block-head"><span className="block-title">Convites pendentes</span><span className="block-sub">Reenvie sem criar outro cliente ou preencher o formulário novamente.</span></div>
      <div style={{ display: 'grid', gap: 10 }}>
        {pendingOnboardings.map((onboarding) => <div key={onboarding.id} style={{ display: 'flex', justifyContent: 'space-between', gap: 16, alignItems: 'center', flexWrap: 'wrap' }}>
          <span>{onboarding.clientName} — {onboarding.pending} usuário(s) pendente(s)</span>
          <button type="button" className="sortbtn" onClick={() => retryInvites(onboarding.id)} disabled={retryingId !== ''}>{retryingId === onboarding.id ? 'Reenviando…' : 'Reenviar convites'}</button>
        </div>)}
      </div>
    </section>}
    <form onSubmit={submit} style={{ display: 'grid', gap: 22, maxWidth: 1040 }}>
      <section className="block" style={{ padding: 22 }}><div className="block-head"><span className="block-title">Identidade da operação</span><span className="block-sub">Dados usados no painel e na identificação interna</span></div><div style={gridStyle}>
        <Field label="Nome de operação" value={form.clientName} onChange={(v) => set('clientName', v)} required />
        <Field label="Slug" value={form.slug} onChange={(v) => set('slug', v)} required placeholder="clinica-exemplo" />
        <Field label="Nicho" value={form.niche} onChange={(v) => set('niche', v)} required />
        <Field label="Fuso horário" value={form.timezone} onChange={(v) => set('timezone', v)} required />
      </div></section>

      <section className="block" style={{ padding: 22 }}><div className="block-head"><span className="block-title">Dados legais completos</span><span className="block-sub">Não inclua credenciais ou segredos neste formulário.</span></div><div style={gridStyle}>
        <Field label="Razão social" value={form.legalName} onChange={(v) => set('legalName', v)} required />
        <Field label="CNPJ" value={form.cnpj} onChange={(v) => set('cnpj', v)} required />
        <Field label="E-mail legal" value={form.legalEmail} onChange={(v) => set('legalEmail', v)} required type="email" />
        <Field label="Telefone legal" value={form.legalPhone} onChange={(v) => set('legalPhone', v)} type="tel" />
        <Field label="Logradouro" value={form.addressLine} onChange={(v) => set('addressLine', v)} required />
        <Field label="Número" value={form.addressNumber} onChange={(v) => set('addressNumber', v)} required />
        <Field label="Complemento" value={form.addressComplement} onChange={(v) => set('addressComplement', v)} />
        <Field label="Bairro" value={form.neighborhood} onChange={(v) => set('neighborhood', v)} required />
        <Field label="Cidade" value={form.city} onChange={(v) => set('city', v)} required />
        <Field label="UF" value={form.state} onChange={(v) => set('state', v)} required placeholder="SP" />
        <Field label="CEP" value={form.postalCode} onChange={(v) => set('postalCode', v)} required />
      </div></section>

      <section className="block" style={{ padding: 22 }}><div className="block-head"><span className="block-title">Identificadores de integração</span><span className="block-sub">Meta, Google e Stevo. Tokens ficam fora daqui e entram por fluxo de credencial.</span></div><div style={gridStyle}>
        <Field label="Meta Business ID" value={form.metaBusinessId} onChange={(v) => set('metaBusinessId', v)} />
        <Field label="Meta Ad Account ID" value={form.metaAdAccountId} onChange={(v) => set('metaAdAccountId', v)} />
        <Field label="Meta Page ID" value={form.metaPageId} onChange={(v) => set('metaPageId', v)} />
        <Field label="Google Manager Customer ID" value={form.googleManagerCustomerId} onChange={(v) => set('googleManagerCustomerId', v)} />
        <Field label="Google Ads Customer ID" value={form.googleAdsCustomerId} onChange={(v) => set('googleAdsCustomerId', v)} />
        <Field label="GA4 Measurement ID" value={form.ga4MeasurementId} onChange={(v) => set('ga4MeasurementId', v)} />
        <Field label="Stevo Instance ID" value={form.stevoInstanceId} onChange={(v) => set('stevoInstanceId', v)} />
      </div></section>

      <section className="block" style={{ padding: 22 }}><div className="block-head"><span className="block-title">Usuários individuais</span><span className="block-sub">Cada pessoa recebe sua própria conta; Gestão e Atendimento são obrigatórios.</span></div><div style={{ display: 'grid', gap: 10 }}>
        {form.users.map((user, index) => <div key={index} style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 180px auto', gap: 10, alignItems: 'end' }}>
          <Field label="Nome" value={user.name} onChange={(v) => updateUser(index, 'name', v)} required />
          <Field label="E-mail individual" value={user.email} onChange={(v) => updateUser(index, 'email', v)} required type="email" />
          <label style={{ display: 'grid', gap: 6, fontSize: 13, color: 'var(--ink-soft)' }}><span>Perfil *</span><select style={inputStyle} value={user.role} onChange={(event) => updateUser(index, 'role', event.target.value as OnboardingRole)}><option value="gestao">Gestão</option><option value="atendimento">Atendimento</option></select></label>
          <button type="button" className="sortbtn" onClick={() => removeUser(index)} disabled={form.users.length <= 2}>Remover</button>
        </div>)}
        <button type="button" className="sortbtn" style={{ justifySelf: 'start' }} onClick={addUser}>+ Adicionar usuário</button>
      </div></section>

      {errors.length > 0 && <div className="login-error" role="alert">{errors.map((error) => <div key={error}>{error}</div>)}</div>}
      {message && <div className="state" role="status" style={{ justifyContent: 'flex-start', minHeight: 0 }}>{message}</div>}
      <button className="btn-primary" type="submit" disabled={saving}>{saving ? 'Salvando…' : 'Salvar onboarding'}</button>
    </form>
  </div>
}
