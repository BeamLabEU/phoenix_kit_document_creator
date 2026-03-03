#set page(
  paper: "a4",
  margin: (top: 2.5cm, bottom: 2cm, x: 2cm),
  header: context {
    if counter(page).get().first() > 1 [
      #text(size: 8pt, fill: rgb("#666"))[<%= company %> — Service Agreement]
      #h(1fr)
      #text(size: 8pt, fill: rgb("#666"))[SA-2026-0042]
    ]
  },
  footer: context [
    #text(size: 8pt, fill: rgb("#999"))[Confidential]
    #h(1fr)
    #text(size: 8pt, fill: rgb("#999"))[
      Page #counter(page).display("1") of #counter(page).final().first()
    ]
  ],
)

#set text(font: "Linux Libertine", size: 11pt)
#set heading(numbering: "1.")
#set par(justify: true)

// Title
#align(center)[
  #text(size: 22pt, weight: "bold")[Service Agreement]
  #v(4pt)
  #text(size: 10pt, fill: rgb("#666"))[
    Agreement No. SA-2026-0042 — Effective <%= contract_date %>
  ]
]

#v(16pt)

// Parties
#grid(
  columns: (1fr, 1fr),
  gutter: 24pt,
  [
    #text(size: 8pt, fill: rgb("#666"), weight: "bold")[PROVIDER]
    #v(4pt)
    *<%= company %>* \
    123 Innovation Drive \
    San Francisco, CA 94102
  ],
  [
    #text(size: 8pt, fill: rgb("#666"), weight: "bold")[CLIENT]
    #v(4pt)
    *<%= client_name %>* \
    456 Business Avenue \
    New York, NY 10001
  ],
)

#v(16pt)
#line(length: 100%, stroke: 0.5pt + rgb("#ddd"))
#v(8pt)

= Scope of Services

<%= description %>

All deliverables shall meet the quality standards outlined in Section 3 and shall be completed within the timeline agreed upon by both parties.

= Pricing

#table(
  columns: (1fr, auto, auto, auto),
  align: (left, center, right, right),
  stroke: none,
  table.header(
    [*Service*], [*Hours*], [*Rate*], [*Amount*],
  ),
  table.hline(stroke: 1.5pt + rgb("#333")),
  [Backend Development], [120], [\$150/hr], [\$18,000],
  [Frontend Development], [80], [\$140/hr], [\$11,200],
  [UI/UX Design], [40], [\$130/hr], [\$5,200],
  [Project Management], [30], [\$120/hr], [\$3,600],
  table.hline(stroke: 1.5pt + rgb("#333")),
  table.cell(colspan: 3, align: right)[*Total*],
  [*\$<%= amount %>*],
)

= Terms and Conditions

+ Payment is due within 30 days of invoice date. Late payments are subject to 1.5% monthly interest.

+ Either party may terminate this agreement with 30 days written notice. Work completed prior to termination shall be compensated at the rates specified above.

+ All intellectual property created during this engagement shall be transferred to the Client upon full payment.

+ This agreement shall be governed by the laws of the State of California.

= Confidentiality

Both parties agree to maintain the confidentiality of all proprietary information exchanged during the course of this agreement. This obligation survives termination of the agreement for a period of two (2) years.

#v(1fr)

// Signature blocks
#grid(
  columns: (1fr, 1fr),
  gutter: 40pt,
  [
    #v(40pt)
    #line(length: 100%, stroke: 0.5pt)
    #v(4pt)
    #text(size: 9pt, fill: rgb("#666"))[
      John Smith, CEO \
      <%= company %> \
      Date: #h(1fr) #line(length: 4cm, stroke: 0.5pt)
    ]
  ],
  [
    #v(40pt)
    #line(length: 100%, stroke: 0.5pt)
    #v(4pt)
    #text(size: 9pt, fill: rgb("#666"))[
      <%= client_name %> \
      Client Representative \
      Date: #h(1fr) #line(length: 4cm, stroke: 0.5pt)
    ]
  ],
)
