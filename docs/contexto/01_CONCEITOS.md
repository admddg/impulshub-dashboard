# ImpulsHub — Conceitos e metodologia

> Este arquivo explica **como pensar** sobre os números do projeto. Toda
> decisão de frontend que envolva métrica passa por aqui primeiro.

---

## 1. As duas réguas de análise

Todo número no dashboard responde a **uma** de duas perguntas. Elas são
diferentes e nunca devem ser misturadas na mesma tabela ou aba.

### Régua A — Coorte (safra de leads)

> "O que aconteceu com os leads que entraram neste período?"

Um lead pertence à safra do dia em que **nasceu**. Tudo que ele fizer
depois (agendar, ganhar, comprar) conta na safra dele — não na data em que
o evento aconteceu.

**Data de referência:** `lead_date`
**Usada em:** Visão Geral, Funil, Canais, Meta Ads, Google Ads
**Por quê:** avaliar se o investimento em mídia virou resultado. O
resultado demora a maturar, então precisa ser rastreado até a origem.

**Consequência esperada:** períodos curtos sempre mostram menos conversão
que períodos longos — parte dos leads ainda não teve tempo de avançar. Não
é bug. Foi por isso que o seletor de "7 dias" foi removido.

### Régua B — Diário (atividade operacional)

> "O que aconteceu neste dia específico?"

Cada evento conta na data real em que aconteceu, sem olhar para quando o
lead nasceu.

**Data de referência:** data real do evento
**Usada em:** Diário, Eventos, Leads
**Por quê:** acompanhamento do dia a dia — "o que está rolando agora".

### Exemplo que ilustra a diferença

```
Lead entra:     dia 1
Agenda:         dia 5
Ganha:          dia 12

Régua A (Funil):  todos os três marcos pertencem à safra do dia 1
Régua B (Diário): cada marco aparece no seu próprio dia
```

**Regra de ouro:** uma aba inteira responde A **ou** B. Se precisar das
duas visões do mesmo dado, são duas abas.

---

## 2. Grãos oficiais (o que cada entidade representa)

| Entidade | Grão | Regra |
|---|---|---|
| Evento CRM | `event_id` | Cada evento normalizado é um fato individual |
| Lead / jornada | `client_id + contact_id` | Exige evento `lead` explícito |
| Oportunidade | `client_id + opportunity_id` | Unidade comercial |
| Venda | Uma oportunidade ganha | Uma pessoa pode ter várias |
| Meta Ads | Anúncio por dia | Toda a hierarquia na mesma linha |
| Google Ads | Anúncio por dia | Campanha, grupo e anúncio são dimensões |
| Google Keywords | Palavra-chave por dia | Grão separado, evita multiplicação |
| Performance | Cliente por data | Consolida mídia, coorte e atividade |

**Por que isso importa:** o funil de pessoas, o funil comercial e a
atividade de eventos **não têm o mesmo grão**. Podem ser comparados, mas
nunca somados como se fossem a mesma coisa.

---

## 3. Pessoa ≠ Oportunidade ≠ Venda

Esta distinção corrigiu um erro conceitual antigo (receita deduplicada por
contato, que fazia recompras desaparecerem).

```
Contato A
  ├── Oportunidade 1 → ganha
  ├── Oportunidade 2 → ganha
  └── Oportunidade 3 → perdida

Resultado correto:
  1 pessoa
  3 oportunidades
  2 vendas
```

**Consequências:**
- Receita não é deduplicada por contato
- Uma pessoa pode contribuir com mais de uma venda
- "Compradores" e "vendas" são métricas **diferentes**
- O funil de pessoas não mede número de oportunidades

### Mapeamento oficial dos campos (nunca substituir um pelo outro)

```
Ganhos                    → crm_ganhos
Compradores de aquisição  → acquisition_buying_contacts
Vendas de aquisição       → acquisition_sales
Vendas totais da coorte   → cohort_total_sales
Vendas fechadas           → closed_sales
```

**`crm_ganhos`** = quantos contatos que entraram como lead no período
chegaram ao marco de ganho no CRM. É métrica de **jornada por pessoa**,
não contagem de oportunidades.

**Evidência de que não são intercambiáveis** (Royal, 01/04 a 15/07/2026):
```
crm_ganhos:                  33
acquisition_buying_contacts:  0
acquisition_sales:            0
cohort_total_sales:           2
```

---

## 4. NULL ≠ zero

```
NULL = valor não informado, indisponível ou incompleto
0    = valor real igual a zero
```

Essa distinção controla receita, ticket médio, CAC e ROAS. Quando a
informação financeira não está completa, o banco **não produz** um
indicador aparentemente preciso.

**Regras:**
- Receita permanece `NULL` quando nenhum valor foi informado
- ROAS permanece `NULL` quando a receita é incompleta
- Flags `*_is_complete` sinalizam quando confiar no número

**No frontend:** exibir `—` (traço simples). Não usar textos longos tipo
"Valor não informado" — o usuário achou visualmente poluído.

| Situação | Exibição |
|---|---|
| Receita sem valor preenchido | `—` |
| ROAS com receita incompleta | `—` |
| CAC sem compradores | `—` |
| CPL sem leads pagos | `—` |
| Leads/agendados zero | `0` (é zero real) |

---

## 5. Atribuição estritamente técnica

Canal **nunca** é inferido por texto, nome de campanha ou origem escrita.

| Classificação | Evidência aceita |
|---|---|
| Meta Ads | `meta_ad_id` |
| Google Ads | `google_campaign_id`, `google_adgroup_id`, `google_ad_id`, `gclid`, `gbraid`, `wbraid` |
| Conflito | IDs de Meta e Google no mesmo lead |
| Não atribuído | Nenhuma evidência técnica |

`lead_origem` e `lead_entrada` são preservados como **campos brutos
independentes**. Servem para leitura operacional, mas não substituem a
plataforma atribuída.

**No frontend:** as duas informações aparecem em colunas separadas com
nomes diferentes — "Plataforma atribuída" (técnica, principal) e "Origem
informada" (bruta, secundária). Nunca fundidas.

**Consequência esperada:** os totais de mídia são sempre ≤ os totais do CRM
amplo. A diferença é o volume que o CRM classifica como "Meta Ads" pela
origem escrita, mas sem o `meta_ad_id` que liga ao anúncio específico.
Isso não é erro — é a diferença entre atribuição rigorosa e origem ampla.

---

## 6. `event_code` é o fato oficial

`pipeline_stage` e `status` continuam disponíveis, mas **não podem
substituir o evento** — foram encontrados casos onde o estágio bruto
divergia do evento recebido (ex: `event_code = 'agendado'` com
`pipeline_stage = 'Perdido'`).

| Campo | Papel |
|---|---|
| `event_code` | Fato canônico |
| `pipeline_stage` | Auditoria bruta |
| `status` | Auditoria bruta |
| `source_event_type` | Proveniência (oficial, rebuild, Clinicorp...) |

**No frontend:** estágio e status brutos podem aparecer em detalhes de
auditoria, nunca como informação principal.

---

## 7. Princípios de arquitetura do banco (que afetam o frontend)

Estes são do time de banco, mas condicionam o que posso consumir:

- **Simplicidade acima de sofisticação.** Uma view nova só existe com
  mudança real de grão, regra canônica indispensável, necessidade de
  segurança ou reutilização clara. Nunca uma view por página.
- **O banco não inventa fatos.** Não infere evento por texto, não fabrica
  oportunidade para dado legado, não classifica recompra sem campo
  explícito, não deduplica silenciosamente.
- **Uma view canônica por canal de mídia** — não uma por nível de
  agrupamento. Conta, campanha, conjunto, anúncio e criativo são
  *dimensões* da mesma fonte.

---

## 8. Checklist antes de adicionar qualquer métrica nova

- [ ] Responde à Régua A (coorte) ou B (diário)?
- [ ] Está numa aba que já é dessa régua?
- [ ] O número vem pronto do banco, ou eu estaria recriando lógica?
- [ ] Se busca dados crus: o volume pode passar de ~1.000 linhas?
- [ ] O número, mesmo correto, comunica a verdade? (ver regra 5 do
      `00_COMECE_AQUI.md`)
- [ ] Como fica quando o dado é `NULL`? (deve ser `—`, nunca `0`)
