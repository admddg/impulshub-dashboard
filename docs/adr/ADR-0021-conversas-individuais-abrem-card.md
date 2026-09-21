# ADR-0021 — Toda conversa individual nova abre card

- **Status:** proposta para a IMP-226 fase 1
- **Data:** 21/09/2026

## Decisão

Toda conversa individual nova abre uma oportunidade em `crm.opportunities`, tanto
quando a primeira mensagem é recebida quanto quando a primeira mensagem é iniciada
por nós. A mensagem recebida começa em `lead`; a mensagem iniciada por nós passa ao
fluxo existente e termina em `atendimento`.

Grupos não abrem card. Mensagens incompletas e endereços LID continuam ignorados.
Uma segunda mensagem enquanto existe oportunidade aberta reutiliza o card e não cria
uma oportunidade duplicada. Se a oportunidade anterior estiver ganha ou perdida,
a próxima conversa pode abrir um novo ciclo.

A regra fica no mesmo ponto do parser `crm.stevo_parse_messages`; a fase 1 remove
apenas as condições que restringiam a criação a mensagens recebidas com
`conversionSource`. Campos de anúncio continuam opcionais e só são gravados quando
o evento os fornece.

## Motivo

O card representa a existência da conversa individual, não apenas uma atribuição
publicitária. Mensagens sem anúncio ainda são conversas comerciais válidas, enquanto
grupos, LID e eventos incompletos não identificam uma conversa individual segura.
