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

A função foi implantada em staging e produção, com `service_role` somente como secret da plataforma. O primeiro cadastro real confirmou o caminho positivo uma vez (2 convites enviados e 2 usuários vinculados). Em novos testes, o submit continua sendo salvo, mas os convites permaneceram `pending_auth`; o diagnóstico do erro de envio ainda está pendente e não deve ser mascarado por novo cadastro ou exclusão de usuários.

## Estado publicado e gate restante

- Migration aplicada em produção `mtxnwtqwfagjzkvgsncs`.
- Edge Function publicada em staging e produção com JWT e secret administrativo somente na plataforma.
- Primeiro teste real: 2 convites enviados e 2 usuários vinculados.
- Dois re-testes posteriores salvaram o onboarding, mas deixaram 2 usuários `pending_auth` em cada tentativa; não há confirmação de envio nesses dois casos.

Gate restante:

1. obter o erro real da invocação da Edge Function/Auth em produção;
2. corrigir o envio e o reenvio sem depender de apagar usuários ou recriar clientes;
3. validar um novo convite com e-mail autorizado e readback de entrega, vínculo e auditoria;
4. manter os registros de teste identificados como teste até a decisão de limpeza, sem apagar dados no escuro.

A migration permite `clients_base.ghl_location_id` nulo porque onboarding novo não usa GHL. O rollback recusa restaurar `NOT NULL` enquanto houver qualquer nulo (`ROLLBACK_BLOCKED_GHL_LOCATION_NULLS`); isso evita uma reversão destrutiva e exige um plano de dados explícito.
