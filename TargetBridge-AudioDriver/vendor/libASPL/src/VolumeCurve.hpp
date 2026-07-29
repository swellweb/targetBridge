// Copyright (c) libASPL authors
// Licensed under MIT

// Copyright (c) 2020 Apple Inc.
// Extracted from BuildingAnAudioServerPlugInAndDriverExtension example

#pragma once

#include "VolumeDecibelPoint.hpp"
#include "VolumeRawPoint.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <map>

namespace aspl {

class VolumeCurve
{
public:
    enum
    {
        kLinearCurve = 0,
        kPow1Over3Curve = 1,
        kPow1Over2Curve = 2,
        kPow3Over4Curve = 3,
        kPow3Over2Curve = 4,
        kPow2Over1Curve = 5,
        kPow3Over1Curve = 6,
        kPow4Over1Curve = 7,
        kPow5Over1Curve = 8,
        kPow6Over1Curve = 9,
        kPow7Over1Curve = 10,
        kPow8Over1Curve = 11,
        kPow9Over1Curve = 12,
        kPow10Over1Curve = 13,
        kPow11Over1Curve = 14,
        kPow12Over1Curve = 15
    };

    VolumeCurve();
    virtual ~VolumeCurve();

    SInt32 GetMinimumRaw() const;
    SInt32 GetMaximumRaw() const;
    Float32 GetMinimumDB() const;
    Float32 GetMaximumDB() const;

    void SetIsApplyingTransferFunction(bool inIsApplyingTransferFunction)
    {
        mIsApplyingTransferFunction = inIsApplyingTransferFunction;
    }

    UInt32 GetTransferFunction() const
    {
        return mTransferFunction;
    }

    void SetTransferFunction(UInt32 inTransferFunction);

    void AddRange(SInt32 mMinRaw, SInt32 mMaxRaw, Float32 inMinDB, Float32 inMaxDB);
    void ResetRange();
    bool CheckForContinuity() const;

    SInt32 ConvertDBToRaw(Float32 inDB) const;
    Float32 ConvertRawToDB(SInt32 inRaw) const;
    Float32 ConvertRawToScalar(SInt32 inRaw) const;
    Float32 ConvertDBToScalar(Float32 inDB) const;
    SInt32 ConvertScalarToRaw(Float32 inScalar) const;
    Float32 ConvertScalarToDB(Float32 inScalar) const;

private:
    typedef std::map<VolumeRawPoint, VolumeDecibelPoint> CurveMap;

    CurveMap mCurveMap;
    bool mIsApplyingTransferFunction;
    UInt32 mTransferFunction;
    Float32 mRawToScalarExponentNumerator;
    Float32 mRawToScalarExponentDenominator;
};

} // namespace aspl
