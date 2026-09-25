# Onboarding interno v1 — gate de Auth

A tela `/agencia/onboarding` faz um único submit autenticado para a RPC `public.create_internal_onboarding`.

## Persistência entregue

- cria o registro canônico em `public.clients_base` sem fabricar um identificador GHL;
- grava os dados legais, identificadores Meta/Google/Stevo e o ator em `public.internal_onboardings`;
- grava cada usuário em `public.internal_onboarding_users`;
- vincula imediatamente usuários que já existem em `auth.users` a `public.client_users`, usando `manager` para Gestão e `attendant` para Atendimento;
- rejeita o envio sem pelo menos um usuário de cada perfil;
- não aceita senha, token, refresh token, access token ou segredo.

## Gate restante

O formulário não cria contas no Supabase Auth porque a criação/convite exige a API administrativa (`service_role`) e não deve ser exposta ao navegador. Usuários ainda inexistentes ficam com `invite_status = 'pending_auth'` e precisam ser convidados por um fluxo administrativo seguro antes da ativação. Isso é intencional e não é um convite simulado.

Para liberar a operação completa:

1. aplicar `20261005000000_internal_onboarding.sql` em staging;
2. validar a RPC com uma sessão de usuário `agency`;
3. implementar o fluxo server-side de convite Auth com chave administrativa fora do bundle;
4. executar o aceite de isolamento e conferir os vínculos individuais antes de ativar o cliente.

A migration permite `clients_base.ghl_location_id` nulo porque onboarding novo não usa GHL. O rollback só deve ser aplicado depois de confirmar que não existem clientes criados por esta migration com esse campo nulo.
