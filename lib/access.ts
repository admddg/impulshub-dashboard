import { supabase } from '@/lib/supabase'

// Um cliente que o usuário logado tem permissão de ver.
export type ClientAccess = {
  client_id: string
  client_slug: string
  client_name: string
}

// Lista todos os clientes que o usuário logado pode ver.
// A v_client_profile_safe já é protegida por RLS: retorna apenas os clientes
// aos quais o usuário tem acesso via client_users. Então a segurança vem do banco.
export async function getMyClients(): Promise<ClientAccess[]> {
  const { data, error } = await supabase
    .from('v_client_profile_safe')
    .select('client_id, client_slug, client_name')
    .order('client_name')

  if (error) {
    console.error('Erro ao listar clientes:', error.message)
    return []
  }
  return (data ?? []) as ClientAccess[]
}

// Resolve um slug para o cliente correspondente, VALIDANDO acesso.
// Se o usuário não tem acesso àquele slug, a view (protegida por RLS) não
// retorna a linha, e a função devolve null → o chamador bloqueia o acesso.
export async function resolveClient(slug: string): Promise<ClientAccess | null> {
  const { data, error } = await supabase
    .from('v_client_profile_safe')
    .select('client_id, client_slug, client_name')
    .eq('client_slug', slug)
    .maybeSingle()

  if (error) {
    console.error('Erro ao resolver cliente:', error.message)
    return null
  }
  return (data as ClientAccess) ?? null
}
