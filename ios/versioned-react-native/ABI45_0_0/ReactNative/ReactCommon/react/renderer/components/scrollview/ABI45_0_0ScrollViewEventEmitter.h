/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

#include <memory>

#include <folly/dynamic.h>
#include <ABI45_0_0React/ABI45_0_0renderer/components/view/ViewEventEmitter.h>
#include <ABI45_0_0React/ABI45_0_0renderer/core/EventEmitter.h>
#include <ABI45_0_0React/ABI45_0_0renderer/graphics/Geometry.h>

namespace ABI45_0_0facebook {
namespace ABI45_0_0React {

class ScrollViewMetrics {
 public:
  Size contentSize;
  Point contentOffset;
  EdgeInsets contentInset;
  Size containerSize;
  Float zoomScale;
};

class ScrollViewEventEmitter : public ViewEventEmitter {
 public:
  using ViewEventEmitter::ViewEventEmitter;

  void onScroll(const ScrollViewMetrics &scrollViewMetrics) const;
  void onScrollBeginDrag(const ScrollViewMetrics &scrollViewMetrics) const;
  void onScrollEndDrag(const ScrollViewMetrics &scrollViewMetrics) const;
  void onMomentumScrollBegin(const ScrollViewMetrics &scrollViewMetrics) const;
  void onMomentumScrollEnd(const ScrollViewMetrics &scrollViewMetrics) const;

 private:
  void dispatchScrollViewEvent(
      const std::string &name,
      const ScrollViewMetrics &scrollViewMetrics,
      EventPriority priority = EventPriority::AsynchronousBatched) const;
};

} // namespace ABI45_0_0React
} // namespace ABI45_0_0facebook
