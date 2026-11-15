use super::*;
use mijialan_homekit::{BridgeInfo, HomeResult, diagnostics::Checks};

fn l(zh: &str, en: &str) -> String {
    if mijialan_core::localization::english() {
        en.into()
    } else {
        zh.into()
    }
}

impl Dashboard {
    pub(super) fn guide_back(&self, fallback: Page) -> Page {
        if self.session.borrow().guide_child.as_ref() == Some(&self.page) {
            Page::Guide
        } else {
            fallback
        }
    }

    fn guide_open(&mut self, page: Page, cx: &mut Context<Self>) {
        self.go(page.clone(), cx);
        self.session.borrow_mut().guide_child = Some(page);
    }

    fn dismiss_guide(&mut self, cx: &mut Context<Self>) {
        self.go(Page::Devices, cx);
        self.run(cx, |engine| {
            engine
                .store
                .update(|config| config.setup_guide_dismissed = true)?;
            Ok(l("已关闭引导教程", "Setup guide closed"))
        });
    }

    pub(super) fn setup_guide_button(&self, cx: &mut Context<Self>) -> Button {
        Button::new("open-setup-guide")
            .label(l("引导教程", "Setup Guide"))
            .on_click(cx.listener(|this, _, _, cx| this.go(Page::Guide, cx)))
    }

    pub(super) fn setup_guide(&self, compact: bool, cx: &mut Context<Self>) -> AnyElement {
        let config = self.engine.store.config();
        let count = config.devices.len();
        let selected = self
            .engine
            .states()
            .iter()
            .filter(|state| {
                state.device.bridged
                    && homekit_choices(Some(state), &config)
                        .iter()
                        .any(|(_, included)| *included)
            })
            .count();
        let bridge = self.bridge.info();
        let step = |title: String, detail: String| {
            let p = cx.theme();
            div()
                .flex()
                .flex_col()
                .gap_2()
                .p_3()
                .rounded_lg()
                .bg(p.muted)
                .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
                .child(
                    div()
                        .text_sm()
                        .text_color(p.foreground.opacity(0.76))
                        .child(detail),
                )
        };
        let import = step(
            l("导入米家设备", "Import Xiaomi Home Devices"),
            if count == 0 {
                l(
                    "用米家 App 扫码，或使用设备的局域网地址和 Token 手动添加。",
                    "Scan with Xiaomi Home, or add a device using its LAN address and token.",
                )
            } else {
                l(
                    &format!("已添加 {count} 台设备"),
                    &format!("{count} devices added"),
                )
            },
        );
        let selection = step(
            l("选择要桥接的设备", "Choose Devices for Home"),
            if selected == 0 {
                l(
                    "在管理页选择要加入 Apple「家庭」的设备与控件。",
                    "Choose the devices and controls to add to Apple Home.",
                )
            } else {
                l(
                    &format!("已选择 {selected} 台设备"),
                    &format!("{selected} devices selected"),
                )
            },
        );
        let pair = step(
            l("添加到 Apple「家庭」", "Add to Apple Home"),
            if bridge.paired {
                l("家庭桥已配对。", "The bridge is paired.")
            } else if bridge.running && bridge.accessories > 0 {
                l(
                    "在 iPhone「家庭」中点「添加配件」，然后扫描此码。",
                    "In Home on your iPhone, tap Add Accessory and scan this code.",
                )
            } else {
                l(
                    "选择至少一台设备并启用家庭桥接后，这里会显示配对码。",
                    "Select at least one device and start the bridge to show its pairing code.",
                )
            },
        );
        div()
            .flex()
            .flex_col()
            .gap_3()
            .when(compact, |view| view.px_4().pb_4())
            .when(!compact, |view| {
                view.child(self.heading("引导教程", "MijiaLAN", cx))
            })
            .child(
                import.child(
                    div()
                        .flex()
                        .gap_2()
                        .flex_wrap()
                        .child(
                            Button::new("guide-import")
                                .primary()
                                .label(l("扫码导入", "Scan to Import"))
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.guide_open(Page::Login, cx)),
                                ),
                        )
                        .child(
                            Button::new("guide-manual")
                                .label(l("手动添加", "Add Manually"))
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.guide_open(Page::Add, cx)),
                                ),
                        ),
                ),
            )
            .child(
                selection.child(
                    Button::new("guide-choose")
                        .label(l("管理家庭设备", "Manage Home Devices"))
                        .disabled(count == 0)
                        .on_click(cx.listener(|this, _, _, cx| this.guide_open(Page::Bridge, cx))),
                ),
            )
            .child(
                pair.when(
                    !bridge.running && selected > 0 && !config.bridge_enabled,
                    |view| {
                        view.child(
                            Button::new("guide-enable-bridge")
                                .primary()
                                .label(l("启用家庭桥接", "Enable Home Bridge"))
                                .disabled(self.busy > 0 || self.engine.is_demo())
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.set_bridge_enabled(true, cx)),
                                ),
                        )
                    },
                )
                .when(
                    !bridge.running && config.bridge_enabled && bridge.error.is_some(),
                    |view| view.child(self.retry_bridge_button(cx)),
                )
                .when(
                    bridge.running && !bridge.paired && bridge.accessories > 0,
                    |view| view.child(self.pairing_code(&bridge)),
                ),
            )
            .child(
                Button::new("guide-done")
                    .label(if bridge.paired {
                        l("完成", "Done")
                    } else {
                        l("稍后设置", "Set Up Later")
                    })
                    .disabled(self.busy > 0)
                    .on_click(cx.listener(|this, _, _, cx| this.dismiss_guide(cx))),
            )
            .into_any_element()
    }

    pub(super) fn set_bridge_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        if self.busy > 0 || self.engine.is_demo() {
            return;
        }
        let bridge = self.bridge.clone();
        self.run(cx, move |engine| {
            engine
                .store
                .update(|config| config.bridge_enabled = enabled)?;
            if enabled {
                bridge
                    .start()
                    .map_err(|error| mijialan_core::Error::Response(error.to_string()))?;
                Ok(l("家庭桥接已启动", "Home bridge started"))
            } else {
                bridge.stop();
                Ok(l("家庭桥接已停止", "Home bridge stopped"))
            }
        });
    }

    pub(super) fn retry_bridge_button(&self, cx: &mut Context<Self>) -> Button {
        Button::new("retry-bridge")
            .label(l("重试启动", "Retry Starting Bridge"))
            .disabled(self.busy > 0)
            .on_click(cx.listener(|this, _, _, cx| this.set_bridge_enabled(true, cx)))
    }

    pub(super) fn refresh_pairing_button(&self, cx: &mut Context<Self>) -> Button {
        Button::new("refresh-pairing-code")
            .label(l("刷新配对码", "Refresh Setup Code"))
            .disabled(self.busy > 0)
            .on_click(cx.listener(|this, _, _, cx| {
                let bridge = this.bridge.clone();
                this.run(cx, move |_| {
                    bridge
                        .refresh_setup_code()
                        .map_err(|error| mijialan_core::Error::Response(error.to_string()))?;
                    Ok(l("已刷新配对码", "Setup code refreshed"))
                });
            }))
    }

    fn pairing_code(&self, bridge: &BridgeInfo) -> Div {
        div()
            .flex()
            .flex_col()
            .items_center()
            .gap_2()
            .when_some(self.assets.qr(&bridge.uri, 0), |view, path| {
                view.child(
                    div()
                        .size(px(144.))
                        .p_2()
                        .rounded_lg()
                        .bg(rgb(0xffffff))
                        .child(svg().path(path).size_full().text_color(rgb(0x000000))),
                )
            })
            .child(
                div()
                    .text_xl()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(bridge.code.clone()),
            )
    }

    pub(super) fn pairing_diagnostics_button(&self, cx: &mut Context<Self>) -> Button {
        Button::new("open-pairing-diagnostics")
            .label(l("配对诊断", "Pairing Diagnostics"))
            .on_click(cx.listener(|this, _, _, cx| this.go(Page::PairingDiagnostics, cx)))
    }

    pub(super) fn pairing_diagnostics(&self, compact: bool, cx: &mut Context<Self>) -> AnyElement {
        let bridge = self.bridge.info();
        let attempt = self.bridge.setup_attempt();
        let state = cx.global::<crate::diagnostics::Diagnostics>();
        let busy = state.collecting();
        let subtitle = state.subtitle();
        let exported = matches!(state.state(), crate::diagnostics::ExportState::Exported(_));
        let offline = self.session.borrow().probe_offline;
        let mut results = div().flex().flex_wrap().gap_2();
        for (result, title) in [
            (HomeResult::Added, l("已添加", "Added")),
            (
                HomeResult::AlreadyInAnotherHome,
                l("已在另一家庭中", "In Another Home"),
            ),
            (HomeResult::OtherError, l("其他错误", "Other Error")),
        ] {
            results = results.child(
                Button::new(SharedString::from(format!("home-result:{result:?}")))
                    .label(title)
                    .when(
                        attempt.as_ref().and_then(|attempt| attempt.home_result) == Some(result),
                        |button| button.primary(),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.bridge.record_home_result(result);
                        cx.notify();
                    })),
            );
        }
        div().flex().flex_col().gap_3().when(compact, |view| view.px_4().pb_4())
            .when(!compact, |view| view.child(div().flex().items_center().gap_3()
                .child(Button::new("pairing-back").label(l("家庭桥接", "Home Bridge"))
                    .on_click(cx.listener(|this, _, _, cx| this.go(Page::Bridge, cx))))
                .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(l("配对诊断", "Pairing Diagnostics")))))
            .child(div().text_sm().child(l(
                "标记一次尝试，然后在 iPhone「家庭」中扫描配对码。回来记录结果并导出报告。",
                "Mark an attempt, scan the code in Home on your iPhone, then record the result and export a report."
            )))
            .child(Button::new("mark-pair-attempt").label(l("标记配对尝试", "Mark Pairing Attempt"))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.bridge.begin_setup_diagnostics();
                    cx.notify();
                })))
            .when(bridge.running && !bridge.paired, |view| view.child(self.pairing_code(&bridge)))
            .when_some(attempt, |view, _| view.child(div().text_sm()
                .child(l("已标记尝试。请选择 iPhone 上显示的结果。", "Attempt marked. Select the result shown on your iPhone.")))
                .child(results))
            .child(Switch::new("probe-offline").label(l("检查离线设备", "Check Offline Devices")).checked(offline)
                .on_click(cx.listener(|this, enabled: &bool, _, cx| {
                    this.session.borrow_mut().probe_offline = *enabled;
                    cx.notify();
                })))
            .child(div().text_sm().child(subtitle))
            .child(Button::new("export-pairing-diagnostics").primary().label(l("导出配对诊断", "Export Pairing Report"))
                .disabled(busy).on_click(move |_, _, cx| {
                    crate::diagnostics::export_with_checks(cx, false, Checks {
                        probe_offline: offline,
                        browse_bonjour: true,
                    });
                }))
            .when(exported, |view| view.child(Button::new("reveal-pairing-report").label(l("在文件夹中显示", "Show in Folder"))
                .on_click(|_, _, cx| crate::diagnostics::reveal(cx))))
            .into_any_element()
    }

    pub(super) fn saved_login_controls(&self, cx: &mut Context<Self>) -> Div {
        let job = self.session.borrow().login.clone();
        let mut view = div().flex().flex_col().gap_2();
        if let Some(region) = job.saved_region() {
            view = view
                .child(div().text_sm().child(l(
                    &format!("已记住米家登录（{region}）"),
                    &format!("Xiaomi Home login saved ({region})"),
                )))
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap_2()
                        .child(
                            Button::new("reimport-saved-login")
                                .label(l("重新导入", "Re-import Devices"))
                                .disabled(job.busy() || self.busy > 0)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    if this.page != Page::Login {
                                        this.go(Page::Login, cx);
                                    }
                                    this.session.borrow().login.reimport(this.engine.clone());
                                    this.status = l("正在导入设备…", "Importing devices…");
                                    this.error = false;
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("forget-saved-login")
                                .label(l("忘记米家登录", "Forget Xiaomi Home Login"))
                                .disabled(job.busy() || self.busy > 0)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    let login = this.session.borrow().login.clone();
                                    this.run(cx, move |engine| {
                                        login.forget(&engine)?;
                                        Ok(l("已忘记米家登录", "Xiaomi Home login forgotten"))
                                    });
                                })),
                        ),
                );
        }
        view
    }

    pub(super) fn import_complete(&self, cx: &mut Context<Self>) -> Div {
        let login = self.session.borrow().login.clone();
        div().flex().flex_col().gap_2()
            .child(div().text_sm().child(if self.status.is_empty() {
                l("设备已导入", "Devices imported")
            } else {
                self.status.clone()
            }))
            .child(div().text_sm().child(l(
                "记住登录后，此设备上的下次导入可以跳过扫码。登录会加密保存在本机。",
                "Save this login on this computer to re-import without scanning. The session is stored encrypted."
            )))
            .child(Button::new("remember-xiaomi-login").primary().label(l("记住米家登录", "Remember Xiaomi Home Login"))
                .disabled(self.busy > 0).on_click(cx.listener(move |this, _, _, cx| {
                    let login = login.clone();
                    this.run(cx, move |engine| {
                        login.remember(&engine)?;
                        Ok(l("米家登录已保存", "Xiaomi Home login saved"))
                    });
                })))
            .child(Button::new("finish-xiaomi-import").label(l("继续", "Continue"))
                .disabled(self.busy > 0).on_click(cx.listener(|this, _, _, cx| {
                    this.go(this.guide_back(Page::Devices), cx);
                })))
    }
}
