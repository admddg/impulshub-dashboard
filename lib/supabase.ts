import { createClient } from '@supabase/supabase-js'

// Estas duas variáveis vêm do arquivo .env.local (você vai preencher lá).
// A anon/publishable key é segura no frontend porque a RLS do banco protege os dados —
// cada usuário logado só enxerga o próprio client_id.
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

export const supabase = createClient(supabaseUrl, supabaseAnonKey)
