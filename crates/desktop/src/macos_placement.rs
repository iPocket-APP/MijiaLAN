//! Logical-point geometry, independent of AppKit so hidden/offscreen anchors can be tested.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    fn right(self) -> f64 {
        self.x + self.width
    }
    fn top(self) -> f64 {
        self.y + self.height
    }
    fn valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite())
            && self.width > 0.
            && self.height > 0.
    }
}
pub fn visible_anchor(icon: Rect, screens: &[Rect]) -> bool {
    icon.valid()
        && screens.iter().any(|screen| {
            screen.valid()
                && icon.x < screen.right()
                && icon.right() > screen.x
                && icon.y < screen.top()
                && icon.top() > screen.y
                && icon.y + icon.height / 2. >= screen.top() - 64.
        })
}
pub fn place(visible: Rect, icon: Option<Rect>, height: f64) -> Option<Rect> {
    if !visible.valid() {
        return None;
    }
    let gap = 8_f64.min(visible.width / 4.).min(visible.height / 4.);
    let width = 360_f64.min(visible.width - 2. * gap);
    let height = if height.is_finite() {
        height.max(1.).min(visible.height - 2. * gap)
    } else {
        (visible.height - 2. * gap).min(660.)
    };
    let center = icon.map_or(visible.right(), |i| i.x + i.width / 2.);
    let top = icon.map_or(visible.top(), |i| i.y);
    Some(Rect {
        x: (center - width / 2.).clamp(
            visible.x + gap,
            (visible.right() - gap - width).max(visible.x + gap),
        ),
        y: (top - 8. - height).clamp(
            visible.y + gap,
            (visible.top() - gap - height).max(visible.y + gap),
        ),
        width,
        height,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hidden_or_offscreen_menu_icons_use_the_visible_right_edge() {
        let screen = Rect {
            x: 0.,
            y: 0.,
            width: 1440.,
            height: 900.,
        };
        for icon in [
            Rect {
                x: 2000.,
                y: 880.,
                width: 24.,
                height: 20.,
            },
            Rect {
                x: 0.,
                y: 0.,
                width: 24.,
                height: 20.,
            },
            Rect {
                x: 1400.,
                y: 880.,
                width: 0.,
                height: 20.,
            },
        ] {
            assert!(!visible_anchor(icon, &[screen]));
        }
        let visible = Rect {
            height: 875.,
            ..screen
        };
        let panel = place(visible, None, 660.).unwrap();
        assert_eq!(
            panel,
            Rect {
                x: 1072.,
                y: 207.,
                width: 360.,
                height: 660.
            }
        );
        let icon = Rect {
            x: 1200.,
            y: 880.,
            width: 24.,
            height: 20.,
        };
        assert!(visible_anchor(icon, &[screen]));
        assert_eq!(place(visible, Some(icon), 400.).unwrap().x, 1032.);
    }
    #[test]
    fn negative_monitor_coordinates_and_small_work_areas_remain_valid() {
        let screen = Rect {
            x: -1280.,
            y: 200.,
            width: 1280.,
            height: 800.,
        };
        let icon = Rect {
            x: -26.,
            y: 980.,
            width: 24.,
            height: 20.,
        };
        assert!(visible_anchor(icon, &[screen]));
        let p = place(
            Rect {
                height: 775.,
                ..screen
            },
            Some(icon),
            660.,
        )
        .unwrap();
        assert_eq!(p.x, -368.);
        assert_eq!(p.y, 307.);
        for (width, height) in [(240., 90.), (10., 10.), (800., 500.)] {
            let work = Rect {
                x: -100.,
                y: 0.,
                width,
                height,
            };
            let p = place(work, None, 660.).unwrap();
            assert!(
                p.x >= work.x
                    && p.y >= work.y
                    && p.right() <= work.right()
                    && p.top() <= work.top()
            );
        }
    }
}
