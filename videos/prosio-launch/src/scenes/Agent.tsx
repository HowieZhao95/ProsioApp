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

export const agentActions: readonly InteractionAction[] = [
  {
    id: "answer-field",
    frame: 24,
    x: 596,
    y: 416,
    target: { x: 364, y: 396, width: 512, height: 42 },
    travel: 15,
  },
  { id: "type-answer", frame: 30, x: 596, y: 416, type: "key" },
  {
    id: "send-answer",
    frame: 68,
    x: 404,
    y: 488,
    target: { x: 364, y: 477, width: 80, height: 22 },
    travel: 13,
  },
  { id: "read-update", frame: 95, x: 704, y: 285, type: "move", travel: 14 },
];

export const Agent: React.FC = () => {
  const f = useCurrentFrame();
  const state = interactionAt(f, agentActions, { x: 774, y: 513 });
  const sent = state.done("send-answer");
  const running = sent && state.since("send-answer") >= 12;
  const answer = "先完成文案，再制作演示。";
  const draft = answer.slice(
    0,
    Math.floor(state.progress("type-answer", 24) * answer.length),
  );
  const status = running ? "执行中" : "等待你回答";
  const statusColor = running ? "#007AFF" : "#FF9500";
  const receiptVisible = sent && state.since("send-answer") >= 6;
  const bodyTop = receiptVisible ? 153 : 132;
  const shift = bodyTop - 132;
  // Enlarge the actual answer controls after focus without changing their layout.
  // The pointer stays inside this same camera plane throughout the move.
  const focus = state.progress("answer-field", 12) * (1 - state.progress("read-update", 18));

  return (
    <Frame>
      <SceneHeader
        eyebrow="本机 CODEX 任务 · 实验功能"
        title="任务在跑。"
        muted="随时接上话。"
        detail={"看进展，回答当前问题。\n检查回答后，让工作继续。"}
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
          data-interaction-scene="agent"
          style={{
            position: "absolute",
            left: -625 * focus,
            top: -250 * focus,
            width: 900,
            height: 620,
            scale: 1.128888889 + 0.671111111 * focus,
            transformOrigin: "top left",
            fontFamily: native.font,
            color: native.text,
          }}
        >
          <NativeWindow title="Prosio · Agent 任务">
            <div
              style={{
                position: "absolute",
                left: 20,
                top: 48,
                display: "flex",
                alignItems: "center",
                gap: 12,
              }}
            >
              <NativeIcon name="cpu" size={23} color="#007AFF" />
              <div>
                <div style={{ fontSize: 20, fontWeight: 700 }}>Agent 任务</div>
                <div
                  style={{
                    fontSize: 12,
                    color: native.secondary,
                    marginTop: 3,
                  }}
                >
                  查看已经在电脑上启动的任务
                </div>
              </div>
            </div>
            <div
              style={{
                position: "absolute",
                right: 20,
                top: 57,
                display: "flex",
                gap: 10,
              }}
            >
              <NativeButton icon="arrow.clockwise">刷新</NativeButton>
              <NativeButton>暂停监控</NativeButton>
            </div>
            {receiptVisible && (
              <div
                style={{
                  position: "absolute",
                  left: 20,
                  right: 20,
                  top: 104,
                  fontSize: 11,
                  color: "#4B4B50",
                }}
              >
                制作产品发布内容：
                {running
                  ? "原任务已记录此次输入；后续执行结果请查看最新状态。"
                  : "正在发送…"}
              </div>
            )}
            <div
              style={{
                position: "absolute",
                left: 20,
                right: 20,
                top: 108 + shift,
                display: "flex",
                alignItems: "center",
                gap: 6,
                color: native.secondary,
                fontSize: 11,
              }}
            >
              <span
                style={{
                  width: 7,
                  height: 7,
                  borderRadius: "50%",
                  background: "#34C759",
                }}
              />
              <span>监控已开启</span>
              <span>· 已连接运行实例</span>
              <span style={{ marginLeft: "auto" }}>20:26</span>
            </div>
            <div
              style={{
                position: "absolute",
                left: 0,
                right: 0,
                top: bodyTop,
                bottom: 46,
                borderTop: "1px solid #DADADD",
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  position: "absolute",
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 340,
                  background: "#EEEEEF",
                  borderRight: "1px solid #DADADD",
                }}
              >
                <div
                  style={{
                    padding: 12,
                    height: 49,
                    background: "#F7F7F7",
                    boxSizing: "border-box",
                    display: "flex",
                    alignItems: "center",
                    gap: 7,
                  }}
                >
                  <span style={{ fontSize: 12 }}>任务范围</span>
                  <div
                    style={{
                      display: "flex",
                      height: 23,
                      borderRadius: 6,
                      background: "#E4E4E6",
                      fontSize: 11,
                      alignItems: "center",
                    }}
                  >
                    {["需要处理", "执行中", "最近会话"].map((label, i) => (
                      <span
                        key={label}
                        style={{
                          padding: "3px 9px",
                          borderRadius: 5,
                          background: i === 2 ? "#FFFFFF" : "transparent",
                          boxShadow: i === 2 ? "0 1px 3px #0000001A" : "none",
                          color: i === 2 ? "#29292C" : "#7C7C81",
                        }}
                      >
                        {label}
                      </span>
                    ))}
                  </div>
                </div>
                {[
                  {
                    title: "制作产品发布内容",
                    surface: "ChatGPT Work / Codex",
                    label: status,
                    color: statusColor,
                    age: "1 秒前",
                  },
                  {
                    title: "修复登录后的页面跳转",
                    surface: "Codex Desktop",
                    label: "执行中",
                    color: "#007AFF",
                    age: "1 分钟前",
                  },
                  {
                    title: "整理会议材料",
                    surface: "Codex CLI",
                    label: "状态待确认",
                    color: "#8E8E93",
                    age: "10 分钟前",
                  },
                ].map((task, index) => (
                  <div
                    key={task.title}
                    style={{
                      position: "absolute",
                      left: 10,
                      top: 58 + index * 88,
                      width: 320,
                      height: 79,
                      borderRadius: 8,
                      background: index === 0 ? "#DCDCDD" : "transparent",
                      padding: "10px 9px",
                      boxSizing: "border-box",
                    }}
                  >
                    <div
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 8,
                        fontSize: 13,
                        fontWeight: 600,
                      }}
                    >
                      <span
                        style={{
                          width: 7,
                          height: 7,
                          borderRadius: "50%",
                          background: task.color,
                        }}
                      />
                      {task.title}
                    </div>
                    <div
                      style={{
                        fontSize: 11,
                        color: native.secondary,
                        marginTop: 7,
                      }}
                    >
                      {task.surface}
                    </div>
                    <div
                      style={{
                        display: "flex",
                        fontSize: 11,
                        marginTop: 7,
                        color: task.color,
                      }}
                    >
                      {task.label}
                      <span
                        style={{ marginLeft: "auto", color: native.secondary }}
                      >
                        {task.age}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
              <div
                style={{ position: "absolute", left: 364, top: 24, right: 24 }}
              >
                <div style={{ fontSize: 22, fontWeight: 700 }}>
                  制作产品发布内容
                </div>
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 7,
                    marginTop: 18,
                    fontSize: 12,
                  }}
                >
                  <NativeIcon
                    name={
                      running
                        ? "circle.fill"
                        : "person.crop.circle.badge.questionmark"
                    }
                    size={13}
                    color={statusColor}
                  />
                  <span style={{ color: statusColor }}>{status}</span>
                  <span style={{ color: native.secondary, marginLeft: 3 }}>
                    ChatGPT Work / Codex
                  </span>
                </div>
                <div
                  style={{
                    marginTop: 20,
                    height: 88,
                    boxSizing: "border-box",
                    padding: 16,
                    borderRadius: 12,
                    background: "#EDEDEE",
                  }}
                >
                  <div style={{ fontSize: 13, fontWeight: 600 }}>最近活动</div>
                  <div style={{ fontSize: 13, marginTop: 8 }}>
                    {running ? "正在整理产品发布文案" : "已提出结构化问题"}
                  </div>
                  <div
                    style={{
                      fontSize: 11,
                      color: native.secondary,
                      marginTop: 7,
                    }}
                  >
                    记录时间：2026年10月8日 20:26:00
                  </div>
                </div>
              </div>
              {!running ? (
                <>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 214,
                      fontSize: 13,
                      fontWeight: 600,
                    }}
                  >
                    当前问题
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 240,
                      fontSize: 13,
                    }}
                  >
                    先完成文案，还是先制作演示？
                  </div>
                  <div
                    data-action-target="answer-field"
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 264,
                      width: 512,
                      height: 42,
                      padding: "5px 6px",
                      boxSizing: "border-box",
                      border: "1px solid #C9C9CD",
                      borderRadius: 5,
                      background: "#FFFFFF",
                      boxShadow:
                        state.done("answer-field") && !sent
                          ? "0 0 0 3px #007AFF3D"
                          : "none",
                      fontSize: 13,
                      color: draft ? native.text : "#8E8E93",
                    }}
                  >
                    {draft || "回答或补充条件，可用 Prosio 热键语音输入"}
                    {state.done("answer-field") && !sent && (
                      <span
                        style={{ borderLeft: "1px solid #111", marginLeft: 1 }}
                      >
                        {"\u2009"}
                      </span>
                    )}
                  </div>
                  <NativeButton
                    icon="mic"
                    disabled={sent}
                    style={{ position: "absolute", left: 364, top: 315 }}
                  >
                    语音回答
                  </NativeButton>
                  <NativeButton
                    target="send-answer"
                    disabled={!draft || sent}
                    pressed={sent}
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 345,
                      width: 80,
                      boxSizing: "border-box",
                    }}
                  >
                    发送回答
                  </NativeButton>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      right: 24,
                      top: 379,
                      fontSize: 11,
                      color: native.secondary,
                      lineHeight: 1.5,
                    }}
                  >
                    点击单个问题的选项直接发送；多个问题请选好全部答案再发送。
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 421,
                      fontSize: 13,
                      fontWeight: 600,
                    }}
                  >
                    补充当前任务要求
                  </div>
                </>
              ) : (
                <>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 214,
                      fontSize: 13,
                      fontWeight: 600,
                    }}
                  >
                    补充当前任务要求
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      right: 24,
                      top: 241,
                      fontSize: 11,
                      lineHeight: 1.45,
                      color: native.secondary,
                    }}
                  >
                    发送到此任务当前执行的轮次，收到后显示回执。不会批准待审批操作。
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      right: 24,
                      top: 277,
                      height: 58,
                      border: "1px solid #C9C9CD",
                      borderRadius: 5,
                      background: "#FFFFFF",
                      padding: "5px 6px",
                      boxSizing: "border-box",
                      color: "#8E8E93",
                      fontSize: 13,
                    }}
                  >
                    输入补充要求，也可用 Prosio 热键语音输入
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      top: 345,
                      display: "flex",
                      gap: 8,
                    }}
                  >
                    <NativeButton disabled>发送补充要求</NativeButton>
                    <NativeButton icon="mic">语音补充</NativeButton>
                    <NativeButton>请求中断本轮</NativeButton>
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      right: 24,
                      top: 380,
                      fontSize: 11,
                      color: native.secondary,
                      lineHeight: 1.45,
                    }}
                  >
                    原任务已记录此次输入；后续执行结果请查看最新状态。
                  </div>
                  <div
                    style={{
                      position: "absolute",
                      left: 364,
                      right: 24,
                      top: 414,
                      fontSize: 11,
                      color: native.secondary,
                    }}
                  >
                    中断不能撤回已经发生的操作。补充要求不会改变原任务的权限设置。
                  </div>
                </>
              )}
            </div>
            <div
              style={{
                position: "absolute",
                left: 0,
                right: 0,
                bottom: 0,
                height: 46,
                borderTop: "1px solid #DADADD",
                boxSizing: "border-box",
                padding: "10px 12px",
                fontSize: 10,
                lineHeight: 1.5,
                background: "#F5F5F5",
              }}
            >
              <div style={{ maxWidth: 742 }}>
                普通 ChatGPT
                聊天及云端任务尚未接入。已连接任务可回答问题、补充要求或请求中断；审批在来源应用处理。
              </div>
              <span
                style={{
                  position: "absolute",
                  right: 12,
                  bottom: 12,
                  color: "#007AFF",
                }}
              >
                更换数据目录…
              </span>
            </div>
          </NativeWindow>
          <InteractionCursor state={state} scale={0.63} />
        </div>
      </div>
      <Steps
        items={["看进展", "检查回答", "继续执行"]}
        active={running ? 2 : state.done("answer-field") ? 1 : 0}
      />
    </Frame>
  );
};
