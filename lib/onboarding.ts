export type OnboardingRole = 'gestao' | 'atendimento'

export type OnboardingUser = {
  name: string
  email: string
  role: OnboardingRole
}

export type OnboardingForm = {
  clientName: string
  slug: string
  legalName: string
  cnpj: string
  legalEmail: string
  legalPhone: string
  addressLine: string
  addressNumber: string
  addressComplement: string
  neighborhood: string
  city: string
  state: string
  postalCode: string
  niche: string
  timezone: string
  metaBusinessId: string
  metaAdAccountId: string
  metaPageId: string
  googleManagerCustomerId: string
  googleAdsCustomerId: string
  ga4MeasurementId: string
  stevoInstanceId: string
  users: OnboardingUser[]
}

export const EMPTY_ONBOARDING_FORM: OnboardingForm = {
  clientName: '', slug: '', legalName: '', cnpj: '', legalEmail: '', legalPhone: '',
  addressLine: '', addressNumber: '', addressComplement: '', neighborhood: '',
  city: '', state: '', postalCode: '', niche: 'odontologia', timezone: 'America/Sao_Paulo',
  metaBusinessId: '', metaAdAccountId: '', metaPageId: '', googleManagerCustomerId: '',
  googleAdsCustomerId: '', ga4MeasurementId: '', stevoInstanceId: '',
  users: [{ name: '', email: '', role: 'gestao' }, { name: '', email: '', role: 'atendimento' }],
}

export function validateOnboarding(form: OnboardingForm): string[] {
  const errors: string[] = []
  const required: [keyof OnboardingForm, string][] = [
    ['clientName', 'Nome de operação'], ['slug', 'Slug'], ['legalName', 'Razão social'],
    ['cnpj', 'CNPJ'], ['legalEmail', 'E-mail legal'], ['addressLine', 'Logradouro'],
    ['addressNumber', 'Número'], ['neighborhood', 'Bairro'], ['city', 'Cidade'],
    ['state', 'UF'], ['postalCode', 'CEP'],
  ]
  for (const [key, label] of required) if (!String(form[key]).trim()) errors.push(`${label} é obrigatório.`)
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(form.slug.trim())) errors.push('Slug deve conter apenas letras minúsculas, números e hífen.')
  if (!/^\S+@\S+\.\S+$/.test(form.legalEmail.trim())) errors.push('E-mail legal inválido.')
  const users = form.users.filter((user) => user.name.trim() || user.email.trim())
  if (!users.some((user) => user.role === 'gestao')) errors.push('Inclua pelo menos um usuário de Gestão.')
  if (!users.some((user) => user.role === 'atendimento')) errors.push('Inclua pelo menos um usuário de Atendimento.')
  if (users.some((user) => !user.name.trim() || !/^\S+@\S+\.\S+$/.test(user.email.trim()))) errors.push('Cada usuário precisa de nome e e-mail válidos.')
  const emails = users.map((user) => user.email.trim().toLowerCase())
  if (new Set(emails).size !== emails.length) errors.push('Cada usuário deve ter um e-mail individual único.')
  return errors
}

export function onboardingPayload(form: OnboardingForm) {
  return {
    p_client_name: form.clientName.trim(), p_client_slug: form.slug.trim(),
    p_legal_name: form.legalName.trim(), p_cnpj: form.cnpj.trim(),
    p_legal_email: form.legalEmail.trim().toLowerCase(), p_legal_phone: form.legalPhone.trim() || null,
    p_address_line: form.addressLine.trim(), p_address_number: form.addressNumber.trim(),
    p_address_complement: form.addressComplement.trim() || null, p_neighborhood: form.neighborhood.trim(),
    p_city: form.city.trim(), p_state: form.state.trim().toUpperCase(), p_postal_code: form.postalCode.trim(),
    p_niche: form.niche.trim() || 'odontologia', p_timezone: form.timezone,
    p_meta_business_id: form.metaBusinessId.trim() || null, p_meta_ad_account_id: form.metaAdAccountId.trim() || null,
    p_meta_page_id: form.metaPageId.trim() || null, p_google_manager_customer_id: form.googleManagerCustomerId.trim() || null,
    p_google_ads_customer_id: form.googleAdsCustomerId.trim() || null, p_ga4_measurement_id: form.ga4MeasurementId.trim() || null,
    p_stevo_instance_id: form.stevoInstanceId.trim() || null,
    p_users: form.users.filter((user) => user.name.trim() || user.email.trim()).map((user) => ({ name: user.name.trim(), email: user.email.trim().toLowerCase(), role: user.role })),
  }
}
