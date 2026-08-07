// Copyright (c) libASPL authors
// Licensed under MIT

// Copyright (c) 2020 Apple Inc.
// Extracted from BuildingAnAudioServerPlugInAndDriverExtension example

#include "VolumeCurve.hpp"

#include <cmath>
#include <iterator>

namespace aspl {

VolumeCurve::VolumeCurve()
    : mCurveMap()
    , mIsApplyingTransferFunction(true)
    , mTransferFunction(kPow2Over1Curve)
    , mRawToScalarExponentNumerator(2.0f)
    , mRawToScalarExponentDenominator(1.0f)
{
}

VolumeCurve::~VolumeCurve()
{
}

SInt32 VolumeCurve::GetMinimumRaw() const
{
    SInt32 theAnswer = 0;

    if (!mCurveMap.empty()) {
        CurveMap::const_iterator theIterator = mCurveMap.begin();
        theAnswer = theIterator->first.mMinimum;
    }

    return theAnswer;
}

SInt32 VolumeCurve::GetMaximumRaw() const
{
    SInt32 theAnswer = 0;

    if (!mCurveMap.empty()) {
        CurveMap::const_iterator theIterator = mCurveMap.begin();
        std::advance(theIterator, static_cast<int>(mCurveMap.size() - 1));
        theAnswer = theIterator->first.mMaximum;
    }

    return theAnswer;
}

Float32 VolumeCurve::GetMinimumDB() const
{
    Float32 theAnswer = 0;

    if (!mCurveMap.empty()) {
        CurveMap::const_iterator theIterator = mCurveMap.begin();
        theAnswer = theIterator->second.mMinimum;
    }

    return theAnswer;
}

Float32 VolumeCurve::GetMaximumDB() const
{
    Float32 theAnswer = 0;

    if (!mCurveMap.empty()) {
        CurveMap::const_iterator theIterator = mCurveMap.begin();
        std::advance(theIterator, static_cast<int>(mCurveMap.size() - 1));
        theAnswer = theIterator->second.mMaximum;
    }

    return theAnswer;
}

void VolumeCurve::SetTransferFunction(UInt32 inTransferFunction)
{
    mTransferFunction = inTransferFunction;

    // figure out the co-efficients
    switch (inTransferFunction) {
    case kLinearCurve:
        mIsApplyingTransferFunction = false;
        mRawToScalarExponentNumerator = 1.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow1Over3Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 1.0f;
        mRawToScalarExponentDenominator = 3.0f;
        break;

    case kPow1Over2Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 1.0f;
        mRawToScalarExponentDenominator = 2.0f;
        break;

    case kPow3Over4Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 3.0f;
        mRawToScalarExponentDenominator = 4.0f;
        break;

    case kPow3Over2Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 3.0f;
        mRawToScalarExponentDenominator = 2.0f;
        break;

    case kPow2Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 2.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow3Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 3.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow4Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 4.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow5Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 5.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow6Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 6.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow7Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 7.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow8Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 8.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow9Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 9.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow10Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 10.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow11Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 11.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    case kPow12Over1Curve:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 12.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;

    default:
        mIsApplyingTransferFunction = true;
        mRawToScalarExponentNumerator = 2.0f;
        mRawToScalarExponentDenominator = 1.0f;
        break;
    };
}

void VolumeCurve::AddRange(SInt32 inMinRaw,
    SInt32 inMaxRaw,
    Float32 inMinDB,
    Float32 inMaxDB)
{
    VolumeRawPoint theRaw(inMinRaw, inMaxRaw);
    VolumeDecibelPoint theDB(inMinDB, inMaxDB);

    bool isOverlapped = false;
    bool isDone = false;
    CurveMap::iterator theIterator = mCurveMap.begin();
    while ((theIterator != mCurveMap.end()) && !isOverlapped && !isDone) {
        isOverlapped = VolumeRawPoint::Overlap(theRaw, theIterator->first);
        isDone = theRaw >= theIterator->first;

        if (!isOverlapped && !isDone) {
            std::advance(theIterator, 1);
        }
    }

    if (!isOverlapped) {
        mCurveMap.insert(CurveMap::value_type(theRaw, theDB));
    }
}

void VolumeCurve::ResetRange()
{
    mCurveMap.clear();
}

bool VolumeCurve::CheckForContinuity() const
{
    bool theAnswer = true;

    CurveMap::const_iterator theIterator = mCurveMap.begin();
    if (theIterator != mCurveMap.end()) {
        SInt32 theRaw = theIterator->first.mMinimum;
        Float32 theDB = theIterator->second.mMinimum;
        do {
            SInt32 theRawMin = theIterator->first.mMinimum;
            SInt32 theRawMax = theIterator->first.mMaximum;
            SInt32 theRawRange = theRawMax - theRawMin;

            Float32 theDBMin = theIterator->second.mMinimum;
            Float32 theDBMax = theIterator->second.mMaximum;
            Float32 theDBRange = theDBMax - theDBMin;

            theAnswer = theRaw == theRawMin;
            theAnswer = theAnswer && (theDB == theDBMin);

            theRaw += theRawRange;
            theDB += theDBRange;

            std::advance(theIterator, 1);
        }
        while ((theIterator != mCurveMap.end()) && theAnswer);
    }

    return theAnswer;
}

SInt32 VolumeCurve::ConvertDBToRaw(Float32 inDB) const
{
    // clamp the value to the dB range
    Float32 theOverallDBMin = GetMinimumDB();
    Float32 theOverallDBMax = GetMaximumDB();

    if (inDB < theOverallDBMin) {
        inDB = theOverallDBMin;
    }
    if (inDB > theOverallDBMax) {
        inDB = theOverallDBMax;
    }

    // get the first entry in the curve map;
    CurveMap::const_iterator theIterator = mCurveMap.begin();

    // initialize the answer to the minimum raw of the first item in the curve map
    SInt32 theAnswer = theIterator->first.mMinimum;

    // iterate through the curve map until we run out of dB
    bool isDone = false;
    while (!isDone && (theIterator != mCurveMap.end())) {
        SInt32 theRawMin = theIterator->first.mMinimum;
        SInt32 theRawMax = theIterator->first.mMaximum;
        SInt32 theRawRange = theRawMax - theRawMin;

        Float32 theDBMin = theIterator->second.mMinimum;
        Float32 theDBMax = theIterator->second.mMaximum;
        Float32 theDBRange = theDBMax - theDBMin;

        Float32 theDBPerRaw = theDBRange / static_cast<Float32>(theRawRange);

        // figure out how many steps we are into this entry in the curve map
        if (inDB > theDBMax) {
            // we're past the end of this one, so add in the whole range for this entry
            theAnswer += theRawRange;
        } else {
            // it's somewhere within the current entry
            // figure out how many steps it is
            Float32 theNumberRawSteps = inDB - theDBMin;
            theNumberRawSteps /= theDBPerRaw;

            // only move in whole steps
            theNumberRawSteps = roundf(theNumberRawSteps);

            // add this many steps to the answer
            theAnswer += static_cast<SInt32>(theNumberRawSteps);

            // mark that we are done
            isDone = true;
        }

        // go to the next entry in the curve map
        std::advance(theIterator, 1);
    }

    return theAnswer;
}

Float32 VolumeCurve::ConvertRawToDB(SInt32 inRaw) const
{
    Float32 theAnswer = 0;

    // clamp the raw value
    SInt32 theOverallRawMin = GetMinimumRaw();
    SInt32 theOverallRawMax = GetMaximumRaw();

    if (inRaw < theOverallRawMin) {
        inRaw = theOverallRawMin;
    }
    if (inRaw > theOverallRawMax) {
        inRaw = theOverallRawMax;
    }

    // figure out how many raw steps need to be taken from the first one
    SInt32 theNumberRawSteps = inRaw - theOverallRawMin;

    // get the first item in the curve map
    CurveMap::const_iterator theIterator = mCurveMap.begin();

    // initialize the answer to the minimum dB of the first item in the curve map
    theAnswer = theIterator->second.mMinimum;

    // iterate through the curve map until we run out of steps
    while ((theNumberRawSteps > 0) && (theIterator != mCurveMap.end())) {
        // compute some values
        SInt32 theRawMin = theIterator->first.mMinimum;
        SInt32 theRawMax = theIterator->first.mMaximum;
        SInt32 theRawRange = theRawMax - theRawMin;

        Float32 theDBMin = theIterator->second.mMinimum;
        Float32 theDBMax = theIterator->second.mMaximum;
        Float32 theDBRange = theDBMax - theDBMin;

        Float32 theDBPerRaw = theDBRange / static_cast<Float32>(theRawRange);

        // there might be more steps than the current map entry accounts for
        SInt32 theRawStepsToAdd = std::min(theRawRange, theNumberRawSteps);

        // add this many steps worth of db to the answer;
        theAnswer += theRawStepsToAdd * theDBPerRaw;

        // figure out how many steps are left
        theNumberRawSteps -= theRawStepsToAdd;

        // go to the next map entry
        std::advance(theIterator, 1);
    }

    return theAnswer;
}

Float32 VolumeCurve::ConvertRawToScalar(SInt32 inRaw) const
{
    // get some important values
    Float32 theDBMin = GetMinimumDB();
    Float32 theDBMax = GetMaximumDB();
    Float32 theDBRange = theDBMax - theDBMin;
    SInt32 theRawMin = GetMinimumRaw();
    SInt32 theRawMax = GetMaximumRaw();
    SInt32 theRawRange = theRawMax - theRawMin;

    // range the raw value
    if (inRaw < theRawMin) {
        inRaw = theRawMin;
    }
    if (inRaw > theRawMax) {
        inRaw = theRawMax;
    }

    // calculate the distance in the range inRaw is
    Float32 theAnswer =
        static_cast<Float32>(inRaw - theRawMin) / static_cast<Float32>(theRawRange);

    // only apply a curve to the scalar values if the dB range is greater than 30
    if (mIsApplyingTransferFunction && (theDBRange > 30.0f)) {
        theAnswer = powf(
            theAnswer, mRawToScalarExponentNumerator / mRawToScalarExponentDenominator);
    }

    return theAnswer;
}

Float32 VolumeCurve::ConvertDBToScalar(Float32 inDB) const
{
    SInt32 theRawValue = ConvertDBToRaw(inDB);
    Float32 theAnswer = ConvertRawToScalar(theRawValue);
    return theAnswer;
}

SInt32 VolumeCurve::ConvertScalarToRaw(Float32 inScalar) const
{
    // range the scalar value
    inScalar = std::min(1.0f, std::max(0.0f, inScalar));

    // get some important values
    Float32 theDBMin = GetMinimumDB();
    Float32 theDBMax = GetMaximumDB();
    Float32 theDBRange = theDBMax - theDBMin;
    SInt32 theRawMin = GetMinimumRaw();
    SInt32 theRawMax = GetMaximumRaw();
    SInt32 theRawRange = theRawMax - theRawMin;

    // have to undo the curve if the dB range is greater than 30
    if (mIsApplyingTransferFunction && (theDBRange > 30.0f)) {
        inScalar = powf(
            inScalar, mRawToScalarExponentDenominator / mRawToScalarExponentNumerator);
    }

    // now we can figure out how many raw steps this is
    Float32 theNumberRawSteps = inScalar * static_cast<Float32>(theRawRange);
    theNumberRawSteps = roundf(theNumberRawSteps);

    // the answer is the minimum raw value plus the number of raw steps
    SInt32 theAnswer = theRawMin + static_cast<SInt32>(theNumberRawSteps);

    return theAnswer;
}

Float32 VolumeCurve::ConvertScalarToDB(Float32 inScalar) const
{
    SInt32 theRawValue = ConvertScalarToRaw(inScalar);
    Float32 theAnswer = ConvertRawToDB(theRawValue);
    return theAnswer;
}

} // namespace aspl
