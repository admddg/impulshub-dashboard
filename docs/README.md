# ImpulsHub — Dashboard multi-cliente de marketing

Painel próprio da agência para os clientes acompanharem resultados reais de marketing
(mídia paga + CRM), com marca própria, multi-cliente e seguro por RLS.

> Este documento existe para que a lógica de construção do projeto sobreviva
> independente de qualquer conversa, ferramenta ou pessoa específica. Se você está
> lendo isso meses depois, comece por aqui.

## Stack

- **Frontend:** Next.js 14 (App Router) + TypeScript + Recharts, hospedado na Vercel.
- **Backend:** Supabase (Postgres + Auth + RLS).
- **Pipeline de dados:** n8n, puxando CRM (GoHighLevel) e mídia (Meta Ads, Google Ads).
- **Domínio:** `painel.impulshub.com.br` (o `app.` ficou reservado para o GHL).

## Os 5 conceitos que guiam tudo

1. **"Tabela guarda, view explica"** — tabelas físicas só recebem o dado cru do
   pipeline (n8n). Toda leitura do dashboard passa por *views* — camadas de SQL que
   organizam e calculam, sem duplicar dado. Criar tabela nova é exceção, não regra.

2. **"CRM vence plataforma"** — o resultado real (lead, agendado, ganho, receita)
   vem sempre do CRM. Meta/Google entram como investimento e como "conversões da
   plataforma" — para **comparar** com a realidade, nunca para substituí-la.

3. **Evento x Oportunidade** — `events_normalized`/`v_crm_events_enriched` é uma
   tabela de eventos (uma linha por avanço no funil: lead, primeira_conversa,
   agendado, ganho, perdido). Nem todo lead vira uma "oportunidade" formal no CRM —
   por isso o funil e a listagem de leads contam a partir dos **eventos por
   contato**, não das oportunidades (que podem ser uma fração pequena do total).

4. **Data do evento, não do insert** — toda data de negócio usa `event_datetime`
   (quando o evento realmente aconteceu), nunca `received_at` (quando entrou no
   banco). Isso evita que backfills históricos amontoem tudo no dia da importação.

5. **Segurança por linha (RLS) em duas camadas** — a RLS do Postgres é a dona da
   segurança: um usuário só enxerga as linhas dos clientes aos quais tem acesso via
   `client_users`. Quando um usuário tem acesso a mais de um cliente, o filtro
   explícito por `client_id` no código escolhe **qual** desses clientes mostrar —
   mas nunca concede acesso por si só. RLS protege, filtro seleciona.

## Estrutura multi-cliente (V10)

```
/dashboard                              redirecionador inteligente:
                                         1 cliente → vai direto; vários → /clientes
/clientes                               seletor de clientes (lista o que o
                                         usuário tem permissão de ver)
/clientes/[client_slug]/dashboard       dashboard real do cliente
```

Regra de ouro: **o slug na URL escolhe qual cliente olhar, mas nunca concede
acesso.** `lib/access.ts` resolve o slug para um `client_id` consultando
`v_client_profile_safe` — como essa view é protegida por RLS, um slug ao qual o
usuário não tem acesso simplesmente não retorna nada, e a tela mostra "acesso não
autorizado". A validação de permissão vem do banco, não do frontend.

## Como diagnosticar problemas (o método que sempre funcionou)

Quando uma tela mostra dado errado ou vazio, antes de mexer em código, confirmar
**no banco**, nessa ordem:

1. A view retorna dado para aquele `client_id`, rodando o SELECT como admin no
   SQL Editor? Se sim, o dado existe.
2. A tabela base tem GRANT SELECT para o role `authenticated`?
3. A tabela base tem RLS ativada? Se sim, **tem política**? (RLS ativada sem
   política = bloqueia tudo silenciosamente, sem erro — foi a causa de mais de um
   bug "funciona no SQL, vazio no app".)
4. A view tem `security_invoker = true`? (Sem isso, ela roda com permissão do
   dono, ignorando a RLS do usuário real.)
5. Só depois de confirmar que o banco entrega o dado certo, olhar o código do
   frontend — geralmente é filtro de data ou nome de coluna divergente.

Ver `docs/sql/` para os scripts que corrigiram problemas reais encontrados por
esse método.

## Ver também

- `docs/ARQUITETURA.md` — mapa completo de qual view alimenta cada aba do
  dashboard, e a lógica de atribuição de canal.
- `docs/sql/` — scripts de migração, na ordem em que foram aplicados.
