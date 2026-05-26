# BarCut

BarCut is a menu bar companion for screenshots that keeps a parallel image history without changing the user's normal macOS screenshot habits.

## Language

**Screenshot**:
An image captured through the user's normal macOS screenshot workflow.
_Avoid_: Capture, clipping

**Clipboard Image**:
An image copied to the clipboard outside BarCut's screenshot workflow.
_Avoid_: Screenshot, pasted screenshot

**Screenshot Destination**:
The folder where macOS would normally save a **Screenshot** for the user.
_Avoid_: BarCut folder, custom screenshot directory

**Image History**:
The finite recent images BarCut keeps available for quick copy and annotation.
_Avoid_: Clipboard history, gallery

**Floating Thumbnail**:
The temporary macOS screenshot preview that appears after a **Screenshot** is taken.
_Avoid_: Preview, corner bubble

**Pending Screenshot**:
A **Screenshot** that has appeared in the **Screenshot Destination** but is not readable by BarCut yet.
_Avoid_: Failed screenshot, partial file

**Standard Screenshot Behavior**:
The normal macOS screenshot experience, including the **Floating Thumbnail** and saving to the **Screenshot Destination**.
_Avoid_: File-only behavior, final screenshot result

**Annotated Image**:
A **Screenshot** or image from **Image History** with one or more **Annotations** applied.
_Avoid_: Edited screenshot, marked-up copy

**Annotation**:
A text or arrow item placed on an image in BarCut.
_Avoid_: Marking, edit

**Annotation Document**:
The in-progress editable image and its **Annotations** before BarCut produces an **Annotated Image**.
_Avoid_: Annotated image draft, overlay list

## Relationships

- A **Screenshot** may be saved in the **Screenshot Destination**.
- A **Screenshot** may appear first as a **Floating Thumbnail**.
- A **Pending Screenshot** may become an **Image History** item once readable.
- A **Screenshot** may appear in **Image History**.
- A **Clipboard Image** may appear in **Image History**.
- An **Annotated Image** is added to **Image History**.
- **Image History** contains readable images only.
- **Image History** includes images observed while BarCut is running.
- **Standard Screenshot Behavior** includes the **Floating Thumbnail** and the **Screenshot Destination**.
- **Image History** represents the same image once, even when it arrives from multiple sources.
- An **Image History** item may gain source facts after it first appears.
- Copying from **Image History** is not a new **Clipboard Image**.
- **Image History** tracks visually distinct images, not every user action.
- **Image History** is ordered by recency.
- An **Annotated Image** has one or more **Annotations**.
- An **Annotation Document** produces an **Annotated Image**.

## Example dialogue

> **Dev:** "Should BarCut save intercepted screenshots somewhere special?"
> **Domain expert:** "No — a **Screenshot** should keep using the **Screenshot Destination**, while BarCut keeps a parallel **Image History**."

## Flagged ambiguities

- "screenshot directory custom to BarCut" was used while the code follows the macOS screenshot destination — resolved: use **Screenshot Destination** for the macOS-aligned folder, not a BarCut-specific folder.
- "marking" was used for text and arrow items — resolved: use **Annotation**.
- "annotated image draft" was considered for in-progress editing state — resolved: use **Annotation Document**.
