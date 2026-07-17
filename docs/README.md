# ImpulsHub Dashboard

Painel de marketing odontológico multi-cliente. Conecta CRM GoHighLevel +
Meta Ads + Google Ads numa visão consolidada por cliente.

**Stack:** Next.js 14 (App Router, TypeScript) + Supabase/Postgres + Recharts.
**Deploy:** Vercel (auto-deploy via push no GitHub). Domínio: `painel.impulshub.com.br`.

## Rotas

```
/login
/dashboard                          redirecionador inteligente
/clientes                           seletor multi-cliente
/clientes/[client_slug]/dashboard   dashboard (8 abas)
/operacao                           saúde dos workflows n8n (só agência)
```

## As duas réguas de análise

**Coorte (régua A):** Visão Geral, Funil, Canais, Meta, Google. Lead conta
na safra em que nasceu; eventos posteriores pertencem a essa safra.

**Diário (régua B):** Diário, Eventos, Leads. Cada evento conta no dia real.

## Fontes canônicas V2 (não substituir por lógica no frontend)

```
get_client_overview_v2()          → Visão Geral (KPIs)
get_meta_ads_summary_v2()         → Meta Ads (todas as sub-abas)
get_google_ads_summary_v2()       → Google Ads (campanhas)
v_client_performance_daily_v2     → gráficos diários
v_crm_funnel_daily_v2             → Funil
v_crm_channels_daily_v2           → Canais
v_client_leads_by_stage_v2        → Leads
v_crm_events_feed_v2              → Eventos
v_crm_events_daily_v2             → Diário
v_google_ads_v2                   → gráficos Google
v_google_keywords_v2              → tabela Keywords
```

## Instalação

```bash
# 1. descompactar o zip, entrar na pasta
cp .env.example .env.local
# editar .env.local: NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY
npm install
npm run dev          # desenvolvimento
npm run build        # validar antes de publicar
```

## Publicar

```bash
# copiar arquivos para a pasta do repositório (a que tem .git)
npm install && npm run build
git add . && git commit -m "mensagem" && git push
# Vercel faz deploy automático
```

## Segurança

- RLS ativa em todas as tabelas base
- 17 views V2 com `security_invoker = true`
- Funções RPC com `SECURITY INVOKER`
- Multi-cliente: `lib/access.ts` valida acesso via `v_client_profile_safe`

## Documentação

- `docs/BANCO_DE_DADOS.md` — schema, metodologia V2, RPCs, segurança
- `docs/ARQUITETURA.md` — mapa fonte→aba, componentes, convenções
- `docs/DIARIO_PROJETO.md` — linha do tempo, bugs e decisões
- `docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` — pipeline n8n
