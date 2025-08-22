/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

declare var undefined: void;

type PropertyDescriptor<T> = any;

declare class Object {}

declare class Function {}

declare class Boolean {}

declare class Number {}

declare class String {
  @@iterator(): Iterator<string>;
}

declare class RegExp {}

declare class $ReadOnlyArray<+T> {
  @@iterator(): Iterator<T>;
}

declare class Array<T> extends $ReadOnlyArray<T> {
  constructor(arrayLength?: number): void;
}

type $ArrayLike<T> = {
  +[indexer: number]: T,
  +length: number,
  ...
};

interface TaggedTemplateLiteralArray extends $ReadOnlyArray<string> {
  +raw: $ReadOnlyArray<string>;
}

// Promise

declare class Promise<+R> {}

// Iterable/Iterator/Generator

interface $Iterator<+Yield,+Return,-Next> {
  @@iterator(): $Iterator<Yield,Return,Next>;
}
interface $Iterable<+Yield,+Return,-Next> {
  @@iterator(): $Iterator<Yield,Return,Next>;
}
interface Generator<+Yield,+Return,-Next> {
  @@iterator(): $Iterator<Yield,Return,Next>;
}

type Iterator<+T> = $Iterator<T,void,void>;
type Iterable<+T> = $Iterable<T,void,void>;

declare function $iterate<T>(p: Iterable<T>): T;

// Async Iterable/Iterator/Generator

interface $AsyncIterator<+Yield,+Return,-Next> {
  @@asyncIterator(): $AsyncIterator<Yield,Return,Next>;
}
interface $AsyncIterable<+Yield,+Return,-Next> {
  @@asyncIterator(): $AsyncIterator<Yield,Return,Next>;
}
interface AsyncGenerator<+Yield,+Return,-Next> {
  @@asyncIterator(): $AsyncIterator<Yield,Return,Next>;
}

/* Type used internally for inferring the type of the yield delegate */
type $IterableOrAsyncIterableInternal<Input, +Yield, +Return, -Next> =
  Input extends $AsyncIterable<any, any, any>
    ? $AsyncIterable<Yield, Return, Next>
    : $Iterable<Yield, Return, Next>;

type AsyncIterator<+T> = $AsyncIterator<T,void,void>;
type AsyncIterable<+T> = $AsyncIterable<T,void,void>;

declare opaque type $Flow$ModuleRef<+T>;
declare opaque type $Flow$EsmModuleMarkerWrapperInModuleRef<+T>: T;
declare opaque type React$CreateElement;

declare var module: {
  exports: any,
  ...
};

declare var exports: {-[key: string]: mixed};

declare module 'react' {
  type Node = any;
  type RefSetter<T> = any;
}

/**
 * You can use this type instead of `any` to avoid triggering `unclear-type` error.
 * However, it's still a clear signal that you should use a better type.
 */
type $FlowFixMe = any;
