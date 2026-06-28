# Reader Header

Configurable KOReader reader header for reflowable documents.

## Install

Copy `readerheader.koplugin` into KOReader's `plugins` directory and enable it in KOReader's plugin manager.

Disable older header user patches such as `2-reader-header-centered.lua` or `2-reader-header-cornered.lua` while this plugin is enabled, otherwise both patches can draw a header.

## Settings

Open a book, then use:

`Reader menu -> Settings (gear icon) -> Status bar -> Header`

Supported template tokens:

`{title}`, `{author}`, `{chapter}`, `{page}`, `{pages}`, `{page_progress}`, `{percentage}`, `{chapter_progress}`, `{pages_left}`, `{pages_left_book}`, `{time}`, `{battery}`, `{separator}`

Default centered template:

`{author} {separator} {title}`
