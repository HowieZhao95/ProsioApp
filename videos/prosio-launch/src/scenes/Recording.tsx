import React from "react";
import { useCurrentFrame } from "remotion";
import { Frame, SceneHeader, Steps } from "../components";
import {
  interactionAt,
  InteractionCursor,
  type InteractionAction,
} from "../interaction";
import { native, NativeIcon } from "../native-ui";
import { NativeButton, NativeWindow } from "./recording-agent-native";

// Local native points. The UI and pointer share this exact transformed plane.
export const recordingActions: readonly InteractionAction[] = [
  { id: "show-shortcut", frame: 6, x: 340, y: 248, type: "key" },
  {
    id: "point-to-content",
    frame: 22,
    x: 570,
    y: 285,
    type: "move",
    travel: 15,
  },
  {
    id: "pause",
    frame: 39,
    x: 717,
    y: 78,
    target: { x: 706, y: 64, width: 22, height: 28 },
    travel: 12,
  },
  {
    id: "resume",
    frame: 65,
    x: 717,
    y: 78,
    target: { x: 706, y: 64, width: 22, height: 28 },
    travel: 0,
  },
  {
    id: "continue-demonstration",
    frame: 81,
    x: 575,
    y: 283,
    type: "move",
    travel: 12,
  },
  {
    id: "stop",
    frame: 99,
    x: 749,
    y: 78,
    target: { x: 738, y: 64, width: 22, height: 28 },
    travel: 12,
  },
  {
    id: "view-material",
    frame: 127,
    x: 476,
    y: 546,
    target: { x: 443, y: 532, width: 66, height: 28 },
    travel: 14,
  },
  {
    id: "export-entry",
    frame: 151,
    x: 828,
    y: 428,
    type: "move",
    target: { x: 779, y: 416, width: 99, height: 24 },
    travel: 16,
  },
];

const Slide: React.FC<{ small?: boolean }> = ({ small = false }) => (
  <div
    style={{
      height: "100%",
      width: "100%",
      background: "#FFFFFF",
      position: "relative",
      overflow: "hidden",
      fontFamily: native.font,
    }}
  >
    <div style={{ padding: small ? "28px 40px" : "50px 64px" }}>
      <div
        style={{
          fontSize: small ? 11 : 13,
          color: "#8A8A8E",
          marginBottom: small ? 17 : 34,
        }}
      >
        发布计划 · 示例内容
      </div>
      <div
        style={{
          fontSize: small ? 27 : 40,
          fontWeight: 650,
          letterSpacing: "-.04em",
          color: "#202124",
        }}
      >
        让好想法，顺畅发生。
      </div>
      <div
        style={{
          fontSize: small ? 14 : 20,
          color: "#70747A",
          marginTop: small ? 12 : 24,
        }}
      >
        更少打断 · 更清楚地表达 · 更顺手地分享
      </div>
      <div
        style={{
          display: "flex",
          gap: small ? 10 : 16,
          marginTop: small ? 30 : 51,
        }}
      >
        {["想法", "表达", "成果"].map((text, index) => (
          <div
            key={text}
            style={{
              borderTop: "2px solid #D5DEE7",
              paddingTop: small ? 10 : 16,
              width: small ? 143 : 203,
              color: "#666E76",
              fontSize: small ? 13 : 17,
            }}
          >
            <span style={{ color: "#A3A9AE", marginRight: 8 }}>
              0{index + 1}
            </span>
            {text}
          </div>
        ))}
      </div>
    </div>
  </div>
);

export const Recording: React.FC = () => {
  const f = useCurrentFrame();
  const state = interactionAt(f, recordingActions, { x: 340, y: 248 });
  const paused = state.done("pause") && !state.done("resume");
  const stopped = state.done("stop");
  const saved = stopped && state.since("stop") >= 9;
  const workspace =
    state.done("view-material") && state.since("view-material") >= 1;
  const finalizingUI = stopped && state.since("stop") >= 1;
  const elapsedFrames =
    f -
    Math.max(0, state.since("pause")) +
    Math.max(0, state.since("resume")) -
    Math.max(0, state.since("stop"));
  const timer = `00:00:${String(12 + Math.floor(elapsedFrames / 30)).padStart(2, "0")}`;
  const shortcutAge = state.since("show-shortcut");
  const shortcutVisible = shortcutAge >= 0 && shortcutAge < 36 && !workspace;
  // Presentation excludes Prosio's own controls; its ring follows the single
  // pointer while over the example document, never a second baked-in cursor.
  const overDocument =
    state.x >= 42 && state.x <= 858 && state.y >= 130 && state.y <= 478;
  const haloVisible = !workspace && !stopped && overDocument;

  return (
    <Frame>
      <SceneHeader
        eyebrow="屏幕录制 × 演示辅助"
        title="你的操作，"
        muted="就是好讲解。"
        detail={"随时暂停和继续。\n原片保存后，导出 MP4。"}
      />
      <div
        style={{
          position: "absolute",
          left: 800,
          top: 212,
          width: 1016,
          height: 700,
          borderRadius: 13,
          overflow: "hidden",
          boxShadow: "0 26px 66px #20273316",
        }}
      >
        <div
          data-interaction-scene="recording"
          style={{
            position: "absolute",
            width: 900,
            height: 620,
            transform: "scale(1.128888889)",
            transformOrigin: "top left",
            background: "#E7ECF1",
            fontFamily: native.font,
            color: native.text,
          }}
        >
          {!workspace && (
            <>
              <div
                style={{
                  position: "absolute",
                  inset: "0 0 auto",
                  height: 24,
                  background: "#F6F7F8C9",
                  display: "flex",
                  alignItems: "center",
                  padding: "0 16px",
                  gap: 20,
                  fontSize: 11,
                }}
              >
                <strong>Finder</strong>
                <span>文件</span>
                <span>编辑</span>
                <span>显示</span>
                <span>前往</span>
                <span>窗口</span>
                <span>帮助</span>
                <span style={{ marginLeft: "auto" }}>周四 20:26</span>
              </div>
              <div
                style={{
                  position: "absolute",
                  left: 42,
                  top: 126,
                  width: 816,
                  height: 352,
                  borderRadius: 6,
                  boxShadow: "0 8px 24px #212B3616",
                  overflow: "hidden",
                }}
              >
                <Slide />
              </div>

              {!saved && (
                <div
                  style={{
                    position: "absolute",
                    left: 590,
                    top: 54,
                    width: 224,
                    height: 48,
                    borderRadius: 14,
                    background: "#F0F0F0F5",
                    boxShadow: "0 3px 14px #22222218",
                  }}
                >
                  <div
                    style={{
                      position: "absolute",
                      left: 16,
                      top: 20.5,
                      width: 7,
                      height: 7,
                      borderRadius: "50%",
                      background: paused ? "#FF9F0A" : "#FF3B30",
                    }}
                  />
                  <div
                    style={{
                      position: "absolute",
                      left: 38,
                      top: 16,
                      fontSize: 12,
                      fontWeight: 500,
                      fontVariantNumeric: "tabular-nums",
                    }}
                  >
                    {timer}
                  </div>
                  {!finalizingUI ? (
                    <>
                      <div
                        data-action-target="pause resume"
                        style={{
                          position: "absolute",
                          left: 116,
                          top: 10,
                          width: 22,
                          height: 28,
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "center",
                          borderRadius: 4,
                          background:
                            state.click &&
                            state.done("pause") &&
                            !state.done("continue-demonstration")
                              ? "#DADADD"
                              : "transparent",
                        }}
                      >
                        <NativeIcon
                          name={paused ? "play.fill" : "pause.fill"}
                          size={12}
                        />
                      </div>
                      <div
                        data-action-target="stop"
                        style={{
                          position: "absolute",
                          left: 148,
                          top: 10,
                          width: 22,
                          height: 28,
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "center",
                        }}
                      >
                        <div
                          style={{
                            width: 12,
                            height: 12,
                            background: "#FF3B30",
                            borderRadius: 3,
                          }}
                        />
                      </div>
                    </>
                  ) : (
                    <div
                      style={{
                        position: "absolute",
                        left: 119,
                        top: 17,
                        width: 13,
                        height: 13,
                        border: "1.5px solid #B9B9BE",
                        borderRightColor: "#66666B",
                        borderRadius: "50%",
                        transform: `rotate(${state.since("stop") * 24}deg)`,
                      }}
                    />
                  )}
                  <div
                    style={{
                      position: "absolute",
                      left: 182,
                      top: 16,
                      display: "flex",
                      alignItems: "center",
                      gap: 2,
                    }}
                  >
                    <NativeIcon name="ellipsis" size={14} />
                    <NativeIcon name="chevron.down" size={7} />
                  </div>
                </div>
              )}

              {saved && (
                <div
                  style={{
                    position: "absolute",
                    left: 305,
                    top: 522,
                    width: 290,
                    height: 48,
                    background: "#F0F0F0F5",
                    borderRadius: 14,
                    boxShadow: "0 3px 14px #22222218",
                  }}
                >
                  <NativeIcon
                    name="checkmark.circle.fill"
                    size={16}
                    color="#34C759"
                    style={{ position: "absolute", left: 16, top: 16 }}
                  />
                  <span
                    style={{
                      position: "absolute",
                      left: 44,
                      top: 16,
                      fontSize: 12,
                      fontWeight: 500,
                    }}
                  >
                    录制已保存
                  </span>
                  <div
                    data-action-target="view-material"
                    style={{
                      position: "absolute",
                      left: 138,
                      top: 10,
                      width: 66,
                      height: 28,
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "center",
                      fontSize: 12,
                      color: "#007AFF",
                    }}
                  >
                    查看素材
                  </div>
                  <NativeIcon
                    name="xmark"
                    size={10}
                    style={{ position: "absolute", left: 254, top: 19 }}
                  />
                </div>
              )}

              {shortcutVisible && (
                <div
                  style={{
                    position: "absolute",
                    left: 391,
                    bottom: 30,
                    minWidth: 118,
                    height: 50,
                    boxSizing: "border-box",
                    display: "flex",
                    justifyContent: "center",
                    alignItems: "center",
                    color: "white",
                    fontSize: 25,
                    fontWeight: 600,
                    padding: "10px 22px",
                    borderRadius: 12,
                    background: shortcutAge < 5 ? "#007AFFF2" : "#000000C7",
                    border:
                      shortcutAge < 5
                        ? "2px solid #FFFFFFCC"
                        : "1px solid #FFFFFF4D",
                  }}
                >
                  ⌘ S
                </div>
              )}
            </>
          )}

          {workspace && (
            <NativeWindow title="屏幕录制">
              <div
                style={{
                  position: "absolute",
                  left: 0,
                  top: 28,
                  bottom: 0,
                  width: 210,
                  background: "#F0F0F0",
                  borderRight: "1px solid #DCDCDD",
                  padding: 16,
                  boxSizing: "border-box",
                }}
              >
                <NativeButton
                  icon="plus"
                  style={{ width: "100%", boxSizing: "border-box" }}
                >
                  新建录制
                </NativeButton>
                <div
                  style={{
                    fontSize: 11,
                    color: native.secondary,
                    marginTop: 14,
                  }}
                >
                  录制素材
                </div>
                <div
                  style={{
                    padding: 10,
                    marginTop: 12,
                    background: "#007AFF1F",
                    borderRadius: 8,
                  }}
                >
                  <div style={{ fontSize: 12, fontWeight: 500 }}>
                    2026年10月8日 20:26
                  </div>
                  <div
                    style={{
                      fontSize: 11,
                      color: native.secondary,
                      marginTop: 5,
                    }}
                  >
                    原片已保存
                  </div>
                </div>
              </div>
              <div
                style={{ position: "absolute", left: 234, top: 52, width: 642 }}
              >
                <div style={{ fontSize: 17, fontWeight: 600 }}>
                  2026年10月8日 20:26
                </div>
                <div
                  style={{
                    fontSize: 11,
                    color: native.secondary,
                    marginTop: 4,
                  }}
                >
                  原片已保存 · 14.4 秒
                </div>
                <NativeButton
                  style={{ position: "absolute", right: 0, top: 1 }}
                >
                  查看原片
                </NativeButton>
              </div>
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  top: 106,
                  width: 642,
                  height: 22,
                  borderRadius: 5,
                  background: "#E3E3E5",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  border: "0.5px solid #C4C4C7",
                  fontSize: 12,
                }}
              >
                发布计划
              </div>
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  top: 143,
                  width: 642,
                  height: 252,
                  borderRadius: 10,
                  overflow: "hidden",
                  background: "#151515",
                }}
              >
                <Slide small />
                <div
                  style={{
                    position: "absolute",
                    left: 18,
                    right: 18,
                    bottom: 9,
                    height: 27,
                    borderRadius: 5,
                    background: "#1F1F1FBD",
                    display: "flex",
                    alignItems: "center",
                    padding: "0 12px",
                    gap: 10,
                    color: "#fff",
                  }}
                >
                  <NativeIcon name="play.fill" size={10} />
                  <span
                    style={{ fontSize: 9, fontVariantNumeric: "tabular-nums" }}
                  >
                    00:00
                  </span>
                  <div
                    style={{
                      height: 3,
                      flex: 1,
                      background: "#FFFFFF55",
                      borderRadius: 2,
                    }}
                  />
                  <span style={{ fontSize: 9 }}>00:14</span>
                </div>
              </div>
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  top: 416,
                  height: 24,
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  fontSize: 11,
                  color: native.secondary,
                }}
              >
                <span>导出范围</span>
                {["0", "14.4"].map((text, i) => (
                  <React.Fragment key={text}>
                    {i === 1 && <span>至</span>}
                    <span
                      style={{
                        width: 70,
                        height: 22,
                        boxSizing: "border-box",
                        border: "1px solid #C7C7CA",
                        borderRadius: 4,
                        background: "#FFFFFF",
                        padding: "2px 5px",
                        color: native.text,
                        fontSize: 12,
                      }}
                    >
                      {text}
                    </span>
                  </React.Fragment>
                ))}
                <span>秒</span>
              </div>
              <NativeButton
                target="export-entry"
                style={{
                  position: "absolute",
                  left: 779,
                  top: 416,
                  width: 99,
                  height: 24,
                  boxSizing: "border-box",
                  background: state.done("export-entry") ? "#E6E6E8" : "#FFF",
                }}
              >
                导出 MP4…
              </NativeButton>
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  right: 24,
                  top: 460,
                  borderTop: "1px solid #DADADD",
                }}
              />
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  top: 478,
                  fontSize: 14,
                  fontWeight: 600,
                }}
              >
                交给剪辑软件
              </div>
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  top: 510,
                  display: "flex",
                  gap: 9,
                }}
              >
                <NativeButton>
                  Final Cut Pro <NativeIcon name="chevron.down" size={8} />
                </NativeButton>
                <NativeButton prominent>导出原片与项目…</NativeButton>
              </div>
              <div
                style={{
                  position: "absolute",
                  left: 234,
                  top: 546,
                  fontSize: 11,
                  color: native.secondary,
                }}
              >
                生成原生多机位 FCPXML；当前软件版本的导入与同步仍需实机验收。
              </div>
            </NativeWindow>
          )}

          {haloVisible && (
            <div
              data-native-pointer-halo
              style={{
                position: "absolute",
                left: state.x - 32,
                top: state.y - 32,
                width: 64,
                height: 64,
                borderRadius: "50%",
                boxSizing: "border-box",
                border: `${state.down ? 5 : 3}px solid #007AFF`,
                background: state.down ? "#007AFF1F" : "transparent",
                pointerEvents: "none",
                zIndex: 58,
              }}
            />
          )}
          <InteractionCursor state={state} scale={0.63} />
        </div>
      </div>
      <Steps
        items={["暂停续录", "查看素材", "导出 MP4"]}
        active={state.done("export-entry") ? 2 : workspace ? 1 : 0}
      />
    </Frame>
  );
};
