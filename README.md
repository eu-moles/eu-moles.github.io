# EU Moles

![EU Moles](src/assets/images/eu-moles-wordmark.png)

**A source-first guide to what happens in the European Parliament—and what it may mean for Europe.**

[EU Moles](https://eu-moles.github.io/) makes European Parliament votes and plenary speeches easier to inspect. It brings together official records, readable vote context, discussion transcripts, and clearly marked assessments of positions that may benefit Russian strategic interests.

The aim is civic, not partisan: help EU citizens look past a vote title, see what their representatives actually voted for or said, and follow the evidence back to the European Parliament’s own record.

## Why this exists

Parliamentary records are public, but they are not always easy to follow. A single sitting can contain dozens of votes, amendments, procedures, documents and speeches. That makes it difficult to answer simple but important questions:

- What would a Yes vote actually have changed?
- Which Member voted for it?
- What was said in the debate around that vote?
- Does a position have a concrete, plausible effect that could benefit Russia’s strategic interests?

EU Moles presents those questions in one place without hiding the source material. Every page is designed to make the official record easier to read—not to replace it.

## What the site provides

- A directory of current Members of the European Parliament, including country, political group and national party.
- Plenary motions with vote totals, individual voting records, source documents and plain-language explanations.
- Discussion transcripts, including translated remarks where available.
- MEP profiles that bring together recorded votes and speeches flagged for potential Russia benefit.
- Filters for motions, discussions and MEP activity connected to a potential Russia-benefit assessment.
- Links back to European Parliament documents and records throughout the site.

Read the full public-facing explanation in the [Methodology](https://eu-moles.github.io/methodology/) page.

## A presentation-led, fully vibe-coded project

This project is fully vibe-coded. The priority is not code elegance for its own sake; it is a trustworthy, clear and professional presentation of public parliamentary data for ordinary people.

That means the implementation is intentionally practical and outcome-driven. The scripts fetch, format and connect official records; the static site turns them into an interface that can be understood without specialist knowledge of EU procedures. Code changes should be judged first by whether they improve clarity, traceability, accessibility and the quality of the public presentation.

## How the evidence is handled

1. **Official records first.** Data comes from published European Parliament sources: meeting records, roll-call results, procedures, agendas, documents and plenary transcripts.
2. **Context before conclusion.** Vote explainers state the real-world policy change and what a Yes vote would do. They link to the official material used.
3. **Visible, limited assessments.** A warning is shown only when the available text supports a concrete direct or indirect mechanism that could benefit Russia’s strategic interests—for example, by reducing European defence capability, support for Ukraine, sanctions enforcement, energy security or counter-disinformation capacity.
4. **No claims about hidden motives.** A flag describes a possible effect of a recorded position. It does not prove intent, loyalty, coordination or an undisclosed affiliation.
5. **Review remains possible.** Readers can open the relevant source document or discussion transcript and judge the evidence themselves.

AI is used for plain-language summaries, translations where needed, and consistent first-pass assessments. AI output is clearly labelled and should be read alongside the linked parliamentary record.

## Run locally

### Requirements

- [Hugo Extended](https://gohugo.io/installation/)
- Bash, `curl`, `jq`, `wget`, `xmllint`, `unzip`, `pdftotext`, and Node.js
- [tgpt](https://github.com/aandrew-me/tgpt) configured with an AI provider for vote explainers and speech assessments

### Preview the site

```bash
./serve.sh
```

Open <http://localhost:1313/>.

### Build the published site

```bash
./build.sh
```

Hugo writes the generated static site to `docs/`.

### Refresh parliamentary data

```bash
./update_data.sh
```

The updater reports its progress, caches official source data, refreshes translations, and generates any missing AI-assisted explainers or assessments. It checks all required commands before starting; configure your `PATH` first if any are missing.

## Project structure

```text
src/
  content/      Public pages and site copy
  data/         Cached European Parliament records and generated analysis
  layouts/      Hugo templates and data-to-page presentation
  assets/       Site styles, browser behaviour and images
scripts/        Data collection, translation and assessment pipeline
docs/           Generated static site for publishing
```

## Important limitations

EU Moles is a research and public-information tool. It can show recorded parliamentary activity and help readers evaluate its possible consequences. It cannot establish why an MEP acted as they did, nor prove covert influence or affiliation. An item without a warning is not a guarantee that it has no political consequence.

If you use the material for journalism, research or advocacy, verify the linked primary sources and describe the assessment as an assessment—not as proof of intent.

## Licence

This project is released under the [GNU General Public License v3.0](LICENSE).
