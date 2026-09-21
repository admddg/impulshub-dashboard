# ADR-0018 — `client_users` como autoridade de papéis do produto

- **Estado:** aceita
- **Contexto:** IMP-213

## Decisão

`public.client_users.role` é a autoridade para visibilidade e autorização do produto.
`crm.tenant_memberships.role` continua descrevendo o papel operacional dentro do CRM e sustentando as chaves relacionais do schema `crm`.

Os papéis de produto ficam assim:

| Papel | Visibilidade |
|---|---|
| `agency` | Todas as contas, todas as abas e painel interno |
| `owner`, `admin`, `manager` | Todas as abas financeiras da própria clínica; CRM permanece exclusivo da agência até flag por cliente |
| `attendant` | Funil e Canais; sem CRM nem métricas financeiras até flag por cliente |
| `viewer` | Alias legado de gestão; não é promovido nesta migration |

Caio e Igor permanecem `agency`. O papel `admin` é mantido por compatibilidade. Novos gestores devem usar `manager` ou `owner`.

A autorização financeira é imposta no PostgreSQL, não apenas no frontend. Um helper `SECURITY DEFINER`, com `search_path = ''`, consulta `client_users` e sustenta três barreiras:

1. as políticas RLS das quatro tabelas de mídia exigem papel financeiro;
2. quatro tabelas externas/brutas deixam de ser legíveis pelos papéis da API, e `events_normalized` concede a `authenticated` somente colunas operacionais;
3. as três RPCs financeiras e todas as 25 views públicas com saída financeira são filtradas pelo helper.

As definições de views e funções são substituídas com `CREATE OR REPLACE`, preservando nome, assinatura e OID. As views financeiras são `security_barrier` e executam como definidor somente depois do filtro por `client_id`. As RPCs de mídia negam o atendente com SQLSTATE `42501`; o overview, as views e as RPCs legadas devolvem zero linhas.

## Por que esta é a opção mais simples

- o login, a RLS existente e o frontend já dependem de `client_users`;
- não cria um terceiro vocabulário de papéis;
- mantém o contrato público usado pelo dashboard;
- bloqueia chamadas diretas pelo PostgREST às tabelas, views e RPCs financeiras, não somente a aba;
- preserva `tenant_memberships` para o que ele já resolve no CRM.

## Reconciliação inicial

Os registros atuais `viewer` permanecem `viewer` em `client_users` e no membership CRM correspondente. `viewer` continua aceito como alias de gestão para não quebrar fluxos legados de convite. A migration não altera memberships operacionais. O usuário explicitamente cadastrado como `attendant` permanece atendente e serve como prova negativa do bloqueio financeiro.

## Consequências

- gestores atuais continuam vendo todos os resultados financeiros;
- a aba CRM permanece exclusiva da agência até existir flag por cliente;
- atendentes não veem as abas financeiras e não conseguem ler dinheiro pelas RPCs ou views públicas diretas;
- gestão e agência acessam finanças pelos contratos públicos filtrados; tabelas brutas e payloads de ingestão não são contratos de leitura do navegador;
- `viewer` deixa de ser atribuído no onboarding normal;
- escrita no CRM continua seguindo as validações existentes; esta ADR não cria proprietário de oportunidade;
- os papéis operacionais elegíveis para CRC e Vendas serão tratados separadamente na IMP-214.

## Rollback

O rollback deve restaurar as políticas e ACLs anteriores, as definições anteriores das três RPCs e 25 views, remover o helper e restaurar o `CHECK` anterior. Como esta migration não altera papéis de usuários, o rollback não deve executar updates em `client_users` ou `crm.tenant_memberships`.
