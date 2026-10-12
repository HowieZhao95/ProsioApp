import React from "react";
import { native, NativeIcon } from "../native-ui";

export const NativeWindow: React.FC<{
  title: string;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ title, children, style }) => (
  <div
    style={{
      position: "absolute",
      inset: 0,
      background: "#F5F5F5",
      border: "1px solid #B9B9BC",
      borderRadius: 10,
      overflow: "hidden",
      color: native.text,
      fontFamily: native.font,
      fontSize: 13,
      boxShadow: "0 12px 35px #0000001C",
      ...style,
    }}
  >
    <div
      style={{
        position: "absolute",
        inset: "0 0 auto",
        height: 28,
        background: "#F0F0F0",
        borderBottom: "1px solid #D9D9DA",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontSize: 12,
        fontWeight: 600,
      }}
    >
      <div
        style={{
          position: "absolute",
          left: 13,
          top: 8,
          display: "flex",
          gap: 8,
        }}
      >
        {["#FF5F57", "#FEBC2E", "#28C840"].map((color) => (
          <i
            key={color}
            style={{
              width: 12,
              height: 12,
              borderRadius: "50%",
              background: color,
              border: "0.5px solid #0000001F",
            }}
          />
        ))}
      </div>
      {title}
    </div>
    {children}
  </div>
);

export const NativeButton: React.FC<{
  children: React.ReactNode;
  icon?: string;
  disabled?: boolean;
  prominent?: boolean;
  pressed?: boolean;
  target?: string;
  style?: React.CSSProperties;
}> = ({
  children,
  icon,
  disabled = false,
  prominent = false,
  pressed = false,
  target,
  style,
}) => (
  <div
    data-action-target={target}
    style={{
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      gap: 5,
      height: 22,
      padding: "0 9px",
      borderRadius: 5,
      border: `0.5px solid ${prominent ? "#0070EA" : "#D1D1D1"}`,
      boxShadow: "0 1px 1px #0000000D",
      background: prominent ? "#007AFF" : pressed ? "#D8D8DA" : "#FFFFFF",
      color: disabled ? "#AAAAAE" : prominent ? "#FFFFFF" : native.text,
      fontFamily: native.font,
      fontSize: 12,
      opacity: disabled ? 0.6 : 1,
      whiteSpace: "nowrap",
      ...style,
    }}
  >
    {icon && <NativeIcon name={icon} size={13} />}
    {children}
  </div>
);
