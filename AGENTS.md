# AGENTS.md — ImpulsHub

## Premissa

**Simplicidade e objetividade.**

Antes de começar qualquer tarefa, responda em uma linha:

1. Qual objetivo do sprint isso serve?
2. É o caminho mais simples que resolve?

**Não coube em uma linha, não começa.** Escale em vez de adivinhar.

## Missão do sprint atual

> O cliente novo entra operando um CRM que não depende do GHL. Prazo: **09/10/2026**.

Não é construir um sistema operacional de crescimento. Não é substituir o GHL dos clientes atuais. É dar ao próximo cliente uma tela onde a clínica trabalha leads, emitindo os eventos que o dashboard e as conversões já consomem.

Royal, Central, QuickClean e ImpulsHub **permanecem no GHL, congelados**. Não existe migração neste sprint.

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
                (enxuto, 14 dias)   (Postgres)           │
                                                         ├──► este painel
  Meta/Google ──► n8n 2.1/2.2 ──► public ──► views V2 ───┤     · abas de resultado (existem)
                                                         │     · aba CRM (nova)
                                      crm ──► n8n 1.1 ──►└──► Meta / Google Conversions
```

Novo: o schema `crm`, o parser do Stevo, a aba CRM, o adaptador de eventos. Só isso.

## Regras

1. **Escopo.** Não está no caminho crítico para o cliente novo entrar sem GHL? Não se constrói. Sem "já que estamos aqui".
2. **Parada.** Nada passa de 2 dias sem entregar algo observável. Estourou, para e escala com evidência.
3. **Sessão.** Uma por vez na branch principal. Worktree só para caminho comprovadamente disjunto, e quem abre, fecha.
4. **Teste.** Onde há dinheiro, perda de dado ou vazamento entre clientes. Não em tudo.
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
