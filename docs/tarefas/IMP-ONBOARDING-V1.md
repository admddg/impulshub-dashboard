# Onboarding interno v1 — gate de Auth

A tela `/agencia/onboarding` faz um único submit autenticado para a RPC `public.create_internal_onboarding`.

## Persistência entregue

- cria o registro canônico em `public.clients_base` sem fabricar um identificador GHL;
- grava os dados legais, identificadores Meta/Google/Stevo e o ator em `public.internal_onboardings`;
- grava cada usuário em `public.internal_onboarding_users`;
- vincula imediatamente usuários que já existem em `auth.users` a `public.client_users`, usando `manager` para Gestão e `attendant` para Atendimento;
- rejeita o envio sem pelo menos um usuário de cada perfil;
- não aceita senha, token, refresh token, access token ou segredo.

## Fluxo seguro de convite individual

A RPC não cria contas Auth. Após o submit, o navegador chama a Edge Function `invite-internal-onboarding`, que:

- valida o JWT e o vínculo ativo `client_users.role = 'agency'`;
- lê apenas os usuários `pending_auth` do onboarding informado;
- usa `SUPABASE_SERVICE_ROLE_KEY` somente no ambiente da Edge Function para `auth.admin.inviteUserByEmail`;
- vincula o `auth_user_id`, a role operacional e grava auditoria com `actor_id`, sem retornar ou persistir qualquer segredo.

A função deve ser implantada/configurada no projeto de staging antes de considerar o aceite concluído. Se ela não estiver disponível, o submit permanece salvo e a UI informa explicitamente que os convites continuam pendentes; não há fallback com `service_role` no browser.

## Gate restante

1. aplicar `20261005000000_internal_onboarding.sql` em staging;
2. implantar `invite-internal-onboarding` em staging com a chave administrativa somente como secret da plataforma;
3. validar RPC, convite individual, retry e isolamento com uma sessão `agency`;
4. conferir auditoria e vínculos antes de ativar o cliente.

A migration permite `clients_base.ghl_location_id` nulo porque onboarding novo não usa GHL. O rollback recusa restaurar `NOT NULL` enquanto houver qualquer nulo (`ROLLBACK_BLOCKED_GHL_LOCATION_NULLS`); isso evita uma reversão destrutiva e exige um plano de dados explícito.
