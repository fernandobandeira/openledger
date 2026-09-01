"use client";

import { useId, type ReactNode } from "react";

import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { cn } from "@/lib/utils";

/** A label, a control and — where the contract has a sharp edge — a hint. */
export function Field({
  label,
  hint,
  children,
  className,
}: {
  label: string;
  hint?: ReactNode;
  children: (id: string) => ReactNode;
  className?: string;
}) {
  const id = useId();
  return (
    <div className={cn("flex flex-col gap-1", className)}>
      <Label htmlFor={id} className="text-[0.72rem] tracking-wide text-dim">
        {label}
      </Label>
      {children(id)}
      {hint ? (
        <p className="text-[0.7rem] leading-snug text-dim">{hint}</p>
      ) : null}
    </div>
  );
}

/**
 * Every text field in this dashboard holds an identifier, a cursor, an amount
 * or an instant, so mono with tabular figures is the default rather than the
 * exception.
 */
export function TextField({
  label,
  value,
  onChange,
  placeholder,
  hint,
  inputMode,
  className,
  onFocus,
  spellCheck = false,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  hint?: ReactNode;
  inputMode?: "text" | "numeric";
  className?: string;
  onFocus?: () => void;
  spellCheck?: boolean;
}) {
  return (
    <Field label={label} hint={hint} className={className}>
      {(id) => (
        <Input
          id={id}
          value={value}
          inputMode={inputMode}
          spellCheck={spellCheck}
          placeholder={placeholder}
          onFocus={onFocus}
          onChange={(event) => onChange(event.target.value)}
          className="h-8 rounded-sm border-edge bg-surface font-mono text-[0.78rem] tabular-nums"
        />
      )}
    </Field>
  );
}

export function InstantField({
  label,
  value,
  onChange,
  hint,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  hint?: ReactNode;
}) {
  return (
    <Field label={label} hint={hint}>
      {(id) => (
        <Input
          id={id}
          type="datetime-local"
          value={value}
          onChange={(event) => onChange(event.target.value)}
          className="h-8 rounded-sm border-edge bg-surface font-mono text-[0.78rem] tabular-nums"
        />
      )}
    </Field>
  );
}

/**
 * A closed set of wire values. Base UI hands back `Value | Value[] | null`
 * because it can multi-select; this dashboard never does, so the string case
 * is the only one taken and nothing is cast.
 */
export function Choice<T extends string>({
  label,
  value,
  options,
  onChange,
  hint,
}: {
  label: string;
  value: T;
  options: { value: T; label: string }[];
  onChange: (value: T) => void;
  hint?: ReactNode;
}) {
  return (
    <Field label={label} hint={hint}>
      {(id) => (
        <Select
          items={options}
          value={value}
          onValueChange={(next) => {
            const chosen = options.find((option) => option.value === next);
            if (chosen) onChange(chosen.value);
          }}
        >
          <SelectTrigger
            id={id}
            className="h-8 w-full rounded-sm border-edge bg-surface font-mono text-[0.78rem]"
          >
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {options.map((option) => (
              <SelectItem key={option.value} value={option.value}>
                <span className="font-mono text-[0.78rem]">{option.label}</span>
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}
    </Field>
  );
}
