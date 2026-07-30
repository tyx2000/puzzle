use gpui::{
    App, Application, Bounds, Context, SharedString, TitlebarOptions, Window, WindowBounds,
    WindowOptions, div, point, prelude::*, px, rgb, size, uniform_list,
};

const WINDOW_WIDTH: f32 = 1773.0;
// GPUI's macOS frame adds a two-point decoration beyond WindowBounds.
const WINDOW_HEIGHT: f32 = 1349.0;
const SIDEBAR_WIDTH: f32 = 260.0;
const TREE_ROWS: usize = 96;
const EDITOR_LINES: usize = 10_000;

const PANEL_BG: u32 = 0xefefef;
const EDITOR_BG: u32 = 0xfbfbfb;
const BORDER: u32 = 0xdcdcdd;
const FOREGROUND: u32 = 0x383a42;
const DIM_TEXT: u32 = 0xa0a1a7;
const BLUE: u32 = 0x4078f2;
const PURPLE: u32 = 0xa626a4;
const ORANGE: u32 = 0x986801;
const GREEN: u32 = 0x50a14f;

struct PuzzleBench;

impl PuzzleBench {
    fn tree_label(index: usize) -> (usize, &'static str, &'static str, u32) {
        const FILES: &[&str] = &[
            "ActivityBarView.swift",
            "AppDelegate.swift",
            "DiffHighlighter.swift",
            "Document.swift",
            "EditorPaneViewController.swift",
            "EditorTabBar.swift",
            "EditorViewController.swift",
            "FileNode.swift",
            "FileTreeViewController.swift",
            "FindBarView.swift",
            "GitPanelViewController.swift",
            "GitService.swift",
            "ImagePreviewView.swift",
            "IndentGuides.swift",
            "LineNumberRulerView.swift",
            "MarkdownPreviewView.swift",
            "MarkdownRenderer.swift",
            "PuzzleSplitViewController.swift",
            "PuzzleTextView.swift",
            "RootViewController.swift",
            "SearchInputView.swift",
            "SearchViewController.swift",
            "Settings.swift",
            "SidebarCellDrawing.swift",
            "SidebarViewController.swift",
            "StatusBarView.swift",
            "SyntaxHighlighter.swift",
            "Theme.swift",
            "WindowResizeHandleView.swift",
            "WorkspaceWindowController.swift",
        ];

        match index {
            0 => (0, "▾", "PuzzleEdit", BLUE),
            1 => (1, "▸", ".obj", DIM_TEXT),
            2 => (1, "▸", "build", GREEN),
            3 => (1, "▸", "Queries", ORANGE),
            4 => (1, "▾", "Sources", GREEN),
            5..=34 => (2, "◆", FILES[index - 5], FOREGROUND),
            35 => (1, "▸", "Tools", ORANGE),
            36 => (1, "▸", "vendor", ORANGE),
            _ => (2, "◇", FILES[(index - 37) % FILES.len()], FOREGROUND),
        }
    }

    fn tree_row(index: usize) -> impl IntoElement {
        let (depth, marker, label, color) = Self::tree_label(index);
        div()
            .h(px(22.0))
            .w_full()
            .flex()
            .flex_row()
            .items_center()
            .pl(px(10.0 + depth as f32 * 14.0))
            .pr_2()
            .text_size(px(12.0))
            .font_family("Monaco")
            .text_color(rgb(color))
            .child(
                div()
                    .w(px(15.0))
                    .text_center()
                    .text_color(rgb(if marker == "◆" || marker == "◇" {
                        DIM_TEXT
                    } else {
                        color
                    }))
                    .child(marker),
            )
            .child(div().ml_1().overflow_hidden().child(label))
    }

    fn editor_row(index: usize) -> impl IntoElement {
        let line = index + 1;
        let (prefix, keyword, body, value) = match index % 5 {
            0 => ("", "final class", " WorkspaceController", " {"),
            1 => ("    ", "private let", " projectURL", ": URL?"),
            2 => ("    ", "func", " openProject", "(_ url: URL) {"),
            3 => ("        ", "guard", " url.isFileURL", " else { return }"),
            _ => ("        ", "let", " displayName", " = \"PuzzleEdit\""),
        };

        div()
            .h(px(22.0))
            .w_full()
            .flex()
            .flex_row()
            .items_center()
            .font_family("Monaco")
            .text_size(px(12.0))
            .text_color(rgb(FOREGROUND))
            .child(
                div()
                    .w(px(64.0))
                    .pr_3()
                    .flex()
                    .justify_end()
                    .text_color(rgb(DIM_TEXT))
                    .child(line.to_string()),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .overflow_hidden()
                    .child(prefix)
                    .child(div().text_color(rgb(PURPLE)).child(keyword))
                    .child(div().text_color(rgb(ORANGE)).child(body))
                    .child(div().text_color(rgb(GREEN)).child(value)),
            )
    }
}

impl Render for PuzzleBench {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tree = uniform_list(
            "project-tree",
            TREE_ROWS,
            cx.processor(|_this, range: std::ops::Range<usize>, _window, _cx| {
                range.map(Self::tree_row).collect::<Vec<_>>()
            }),
        )
        .h_full();

        let editor = uniform_list(
            "editor-lines",
            EDITOR_LINES,
            cx.processor(|_this, range: std::ops::Range<usize>, _window, _cx| {
                range.map(Self::editor_row).collect::<Vec<_>>()
            }),
        )
        .h_full();

        div()
            .size_full()
            .flex()
            .flex_row()
            .bg(rgb(EDITOR_BG))
            .child(
                div()
                    .w(px(SIDEBAR_WIDTH))
                    .h_full()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .bg(rgb(PANEL_BG))
                    .border_r_1()
                    .border_color(rgb(BORDER))
                    .child(
                        div()
                            .h(px(34.0))
                            .flex_none()
                            .flex()
                            .items_center()
                            .px_3()
                            .font_family("Monaco")
                            .text_size(px(12.0))
                            .text_color(rgb(FOREGROUND))
                            .child("Files"),
                    )
                    .child(div().flex_1().overflow_hidden().child(tree))
                    .child(
                        div()
                            .h(px(48.0))
                            .flex_none()
                            .border_t_1()
                            .border_color(rgb(BORDER))
                            .flex()
                            .items_center()
                            .justify_center()
                            .font_family("Monaco")
                            .text_size(px(11.0))
                            .text_color(rgb(DIM_TEXT))
                            .child("Files     Search     Git     Settings"),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .h_full()
                    .flex()
                    .flex_col()
                    .bg(rgb(EDITOR_BG))
                    .child(
                        div()
                            .h(px(40.0))
                            .flex_none()
                            .border_b_1()
                            .border_color(rgb(BORDER))
                            .flex()
                            .items_center()
                            .px_4()
                            .font_family("Monaco")
                            .text_size(px(12.0))
                            .text_color(rgb(FOREGROUND))
                            .child("WorkspaceWindowController.swift    ×"),
                    )
                    .child(div().flex_1().overflow_hidden().child(editor))
                    .child(
                        div()
                            .h(px(24.0))
                            .flex_none()
                            .border_t_1()
                            .border_color(rgb(BORDER))
                            .flex()
                            .items_center()
                            .justify_end()
                            .px_3()
                            .font_family("Monaco")
                            .text_size(px(10.0))
                            .text_color(rgb(DIM_TEXT))
                            .child("Swift    UTF-8    LF    Spaces: 4"),
                    ),
            )
    }
}

fn main() {
    Application::new().run(|cx: &mut App| {
        let bounds = Bounds::new(
            point(px(80.0), px(40.0)),
            size(px(WINDOW_WIDTH), px(WINDOW_HEIGHT)),
        );
        cx.open_window(
            WindowOptions {
                titlebar: Some(TitlebarOptions {
                    title: Some(SharedString::new_static("Puzzle GPUI benchmark")),
                    ..Default::default()
                }),
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(800.0), px(500.0))),
                ..Default::default()
            },
            |_window, cx| cx.new(|_| PuzzleBench),
        )
        .expect("open GPUI benchmark window");
        cx.activate(true);
    });
}
