# AGENTS.md — ImpulsHub

## Premissa

**Simplicidade e objetividade.**

Antes de começar qualquer tarefa, responda em uma linha:

1. Qual objetivo do sprint isso serve?
2. É o caminho mais simples que resolve?

**Não coube em uma linha, não começa.** Escale em vez de adivinhar.

## Missão

> **O sistema é construído para os clientes NOVOS.** Cliente novo entra 100% na nossa estrutura, sem GHL.

Royal, Central e QuickClean **permanecem no GoHighLevel, definitivamente**. Não são alvo de migração — servem como laboratório: aprendizado, modelagem e teste. A **Impuls** é o primeiro cliente de verdade do sistema novo.

Não é construir um sistema operacional de crescimento. Não é substituir o GHL de ninguém. É dar ao próximo cliente uma tela onde a clínica trabalha leads, emitindo os eventos que o dashboard e as conversões já consomem.

**Não há prazo.** O critério de entrada está em [`docs/ROADMAP.md`](docs/ROADMAP.md), que é a fonte única de direção — se este arquivo divergir dele, o ROADMAP vale.

## O que já existe e funciona — não reconstrua

| Peça | Estado |
|---|---|
| Ingestão do Stevo → `stevo_events_raw` | Ao vivo, dois clientes, com `client_id` resolvido e idempotência por `payload_hash` |
| Sync de mídia Meta e Google (n8n `2.1`/`2.2`) | Ao vivo |
| Normalizador de eventos (n8n `1.1 /inbound-events`) | Ao vivo |
| Conversões offline Meta e Google (n8n `1.2`/`1.3`) | Ao vivo — **é o que faz a campanha otimizar** |
| Views V2 e abas de resultado | Em produção |
| Auth, `client_users`, acesso multi-cliente | Em produção |

Tocar em qualquer uma dessas sem tarefa explícita é fora de escopo.

## O que se constrói

```
  Stevo ──► stevo_events_raw ──► parser ──► schema crm ──┐
                 (enxuto)         (Postgres)             │
                                                         ├──► este painel
  Meta/Google ──► n8n 2.1/2.2 ──► public ──► views V2 ───┤     · abas de resultado (existem)
                                                         │     · aba CRM (a construir)
                                      crm ──► n8n 1.1 ──►└──► Meta / Google Conversions
```

## Estado em 20/09/2026

Já **em produção** no projeto `Clients_Base` (`mtxnwtqwfagjzkvgsncs`):

| Peça | Estado |
|---|---|
| Schema `crm`, 14 tabelas, RLS nas 14 | ✅ |
| Parser do Stevo | ✅ roda a cada minuto por `pg_cron` |
| 12 migrations, ledger batendo com o repositório | ✅ |
| Atribuição de mídia na oportunidade | ✅ `ctwa_clid`, `meta_ad_id`, `conversion_source` |
| Ponte de conversões (IMP-205) | ✅ aplicada, **inerte** — flag `false` nos 6 clientes |

**A aba CRM está pronta em `feat/imp-206-crm-tab` e ainda não foi publicada.**
Produção roda `b43b805`, sem ela. O banco está à frente do que está no ar.

Números por cliente e etapas seguintes: [`docs/ROADMAP.md`](docs/ROADMAP.md).

## ⚠️ A restrição que muda como se escreve o frontend

**O navegador não alcança o schema `crm` de jeito nenhum — nem para ler.**

O PostgREST só expõe o schema `public`, e `pgrst.db_schemas` não está definido neste projeto. Hoje não existe uma única view ou função em `public` que toque o `crm`: `supabase.from('opportunities')` não resolve nem para `select`.

O grant de `select` que o `authenticated` tem nas 14 tabelas do `crm` é real, mas inalcançável pelo cliente HTTP. Ele serve para que views em `public` com `security_invoker = true` leiam o `crm` em nome do usuário, com a RLS valendo.

Portanto o caminho é:

| | |
|---|---|
| **Leitura** | views em `public`, `security_invoker = true`, `grant select to authenticated` |
| **Escrita** | funções em `public`, `SECURITY DEFINER`, `grant execute to authenticated`, com `actor_profile_id := auth.uid()` |

O contrato completo está em [`docs/CONTRATO-TELA-CRM.md`](docs/CONTRATO-TELA-CRM.md).

Escrita direta continua exclusiva de `service_role` — o parser e o cron usam esse caminho.

Três camadas, todas no banco:
1. **Grant** — `authenticated` só lê
2. **RLS** — leitura escopada por `crm.is_member(tenant_id)`
3. **Trigger** — ação manual exige ator ativo e não-`viewer`

## Invariantes que o banco impõe

- **Valor ausente permanece pendente, nunca zero.** Há `CHECK` que recusa `value=0` com `value_status='valid'`
- **Todo Perdido referencia um dos 9 motivos canônicos.** Só `outro` exige observação
- **Ganho e Perdido são terminais**
- **Regressão manual exige motivo e não apaga marco.** Por isso `opportunity_milestones` é separada de `opportunity_stage_history`
- **`viewer` não escreve.** Produção tem 10 `admin` e 3 `viewer`

## Identidade de contato — verificado nos dados reais

- Vem **sempre** de `data.Info.Chat`. **Nunca** de `Sender`, que no outbound é `<dígitos>@lid` — o dispositivo do atendente
- **Sem normalização do nono dígito.** Zero colisões em 605 números reais; o JID do WhatsApp já é canônico
- **Contato ≠ oportunidade.** Oportunidade só com entrada comercial (mensagem recebida com `conversionSource`). Sem essa regra o pipeline vira ~75% ruído

## Regras

1. **Escopo.** Não está no caminho crítico para o cliente novo entrar sem GHL? Não se constrói. Sem "já que estamos aqui".
2. **Parada.** Nada passa de 2 dias sem entregar algo observável. Estourou, para e escala com evidência.
3. **Sessão.** Uma por vez na branch principal. Worktree só para caminho comprovadamente disjunto, e quem abre, fecha.
4. **Teste.** Onde há dinheiro, perda de dado ou vazamento entre clientes. Não em tudo.
   Toda mudança em view, política de RLS ou função que leia dados de cliente exige teste de isolamento entre clientes, além do teste de papéis.
5. **Proibido sem "sim" do Caio.** Serviço novo, projeto novo, repositório novo, dependência nova.
6. **Pronto** = comportamento observável. Documento não é entrega.
7. **Segredo** nunca entra em código, log, prompt, fixture ou PR. Preserve como `[REDACTED]`.
8. **Produção é leitura por padrão.** Escrita, migration e deploy exigem aprovação.

## As cinco regras que não se quebram

Nasceram de erro real neste projeto. Cada uma custou tempo de investigação.

1. **O frontend não recria metodologia do banco.** Atribuição, deduplicação, etapa, venda, receita, CAC, ROAS vêm prontos do Postgres. Se o número não vem pronto, peça — não invente a conta em JavaScript. Já houve duas metodologias divergentes em produção por causa disso.
2. **Nunca busque linhas cruas quando o volume pode crescer.** O PostgREST corta acima de ~1.000 linhas **sem erro nenhum**. O sintoma é número errado, em silêncio. Agregue no banco ou pagine explicitamente. Esse bug apareceu quatro vezes.
3. **Confirme a coluna antes de escrever a query.** `information_schema.columns`. Nunca por analogia com outra view.
4. **Valide o plano antes de alterar.** Apresente, espere aval, então codifique. Vale especialmente para o que muda número visível ao cliente.
5. **Número tecnicamente correto que comunica algo falso é pior que número nenhum.** Valor ausente permanece pendente — **nunca vira zero**.

## Onde mora a verdade

- **ClickUp** — fila única. Espaço Plataforma, lista `Sprint 22/09 → 09/10 — CRM sem GHL`. Teto de 3 tarefas em andamento.
- **Este repositório** — código, migrations, evidência.
- **Supabase `Clients_Base`** (`mtxnwtqwfagjzkvgsncs`) — dados canônicos. `public` é o que existe; `crm` é o núcleo novo.
- **ADRs** — em [`admddg/impuls-plataforma`](https://github.com/admddg/impuls-plataforma), repositório arquivado. Vigentes: **ADR-0013** (arquitetura), **ADR-0014** (domínio), **ADR-0015** (GHL), **ADR-0016** (banco e repositório).

## O que não se constrói

Chatwoot ou inbox própria. Impuls Core como serviço separado. Coolify. VPS nova. n8n de staging. Projeto Supabase separado. Round-robin. Motor de frases — está pronto e **congelado** de propósito. Pipeline customizável por clínica. Regex, fuzzy matching ou IA no matching. Onboarding automatizado — com um cliente, faça na mão.

## Válvula

Se o sprint atrasar mais de uma semana, o cliente novo entra no GHL e migra depois. Custa uma subconta. **Não é fracasso** — é a decisão certa tomada com a cabeça fria, antes da pressão.
