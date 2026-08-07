// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-strings.py
// Source: CoreAudio/AudioServerPlugIn.h
// Timestamp: Sun Apr 13 14:12:49 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include "Strings.hpp"

namespace aspl {

std::string ClassIDToString(AudioClassID classID)
{
    switch (classID) {
    case 'togl':
        return "kAudioBooleanControlClassID";
    case 'abox':
        return "kAudioBoxClassID";
    case 'clip':
        return "kAudioClipLightControlClassID";
    case 'aclk':
        return "kAudioClockDeviceClassID";
    case 'clck':
        return "kAudioClockSourceControlClassID";
    case 'actl':
        return "kAudioControlClassID";
    case 'dest':
        return "kAudioDataDestinationControlClassID";
    case 'dsrc':
        return "kAudioDataSourceControlClassID";
    case 'adev':
        return "kAudioDeviceClassID";
    case 'endp':
        return "kAudioEndPointClassID";
    case 'edev':
        return "kAudioEndPointDeviceClassID";
    case 'hipf':
        return "kAudioHighPassFilterControlClassID";
    case 'jack':
        return "kAudioJackControlClassID";
    case 'subm':
        return "kAudioLFEMuteControlClassID";
    case 'subv':
        return "kAudioLFEVolumeControlClassID";
    case 'levl':
        return "kAudioLevelControlClassID";
    case 'nlvl':
        return "kAudioLineLevelControlClassID";
    case 'lsnb':
        return "kAudioListenbackControlClassID";
    case 'mute':
        return "kAudioMuteControlClassID";
    case 'aobj':
        return "kAudioObjectClassID";
    case 'phan':
        return "kAudioPhantomPowerControlClassID";
    case 'phsi':
        return "kAudioPhaseInvertControlClassID";
    case 'aplg':
        return "kAudioPlugInClassID";
    case 'slct':
        return "kAudioSelectorControlClassID";
    case 'sldr':
        return "kAudioSliderControlClassID";
    case 'solo':
        return "kAudioSoloControlClassID";
    case 'span':
        return "kAudioStereoPanControlClassID";
    case 'astr':
        return "kAudioStreamClassID";
    case 'talb':
        return "kAudioTalkbackControlClassID";
    case 'trpm':
        return "kAudioTransportManagerClassID";
    case 'vlme':
        return "kAudioVolumeControlClassID";
    default:
        return CodeToString(classID);
    }
}

std::string PropertySelectorToString(AudioObjectPropertySelector selector)
{
    switch (selector) {
    case 'bcvl':
        return "kAudioBooleanControlPropertyValue";
    case 'bxon':
        return "kAudioBoxPropertyAcquired";
    case 'bxof':
        return "kAudioBoxPropertyAcquisitionFailed";
    case 'buid':
        return "kAudioBoxPropertyBoxUID";
    case 'bcl#':
        return "kAudioBoxPropertyClockDeviceList";
    case 'bdv#':
        return "kAudioBoxPropertyDeviceList";
    case 'bhau':
        return "kAudioBoxPropertyHasAudio";
    case 'bhmi':
        return "kAudioBoxPropertyHasMIDI";
    case 'bhvi':
        return "kAudioBoxPropertyHasVideo";
    case 'bpro':
        return "kAudioBoxPropertyIsProtected";
    case 'cuid':
        return "kAudioClockDevicePropertyDeviceUID";
    case 'celm':
        return "kAudioControlPropertyElement";
    case 'cscp':
        return "kAudioControlPropertyScope";
    case 'nsr#':
        return "kAudioDevicePropertyAvailableNominalSampleRates";
    case 'clok':
        return "kAudioDevicePropertyClockAlgorithm";
    case 'clkd':
        return "kAudioDevicePropertyClockDomain";
    case 'cstb':
        return "kAudioDevicePropertyClockIsStable";
    case 'capp':
        return "kAudioDevicePropertyConfigurationApplication";
    case 'dflt':
        return "kAudioDevicePropertyDeviceCanBeDefaultDevice";
    case 'sflt':
        return "kAudioDevicePropertyDeviceCanBeDefaultSystemDevice";
    case 'livn':
        return "kAudioDevicePropertyDeviceIsAlive";
    case 'goin':
        return "kAudioDevicePropertyDeviceIsRunning";
    case 'icon':
        return "kAudioDevicePropertyIcon";
    case 'hidn':
        return "kAudioDevicePropertyIsHidden";
    case 'ltnc':
        return "kAudioDevicePropertyLatency";
    case 'muid':
        return "kAudioDevicePropertyModelUID";
    case 'nsrt':
        return "kAudioDevicePropertyNominalSampleRate";
    case 'srnd':
        return "kAudioDevicePropertyPreferredChannelLayout";
    case 'dch2':
        return "kAudioDevicePropertyPreferredChannelsForStereo";
    case 'akin':
        return "kAudioDevicePropertyRelatedDevices";
    case 'saft':
        return "kAudioDevicePropertySafetyOffset";
    case 'stm#':
        return "kAudioDevicePropertyStreams";
    case 'tran':
        return "kAudioDevicePropertyTransportType";
    case 'ring':
        return "kAudioDevicePropertyZeroTimeStampPeriod";
    case 'acom':
        return "kAudioEndPointDevicePropertyComposition";
    case 'agrp':
        return "kAudioEndPointDevicePropertyEndPointList";
    case 'priv':
        return "kAudioEndPointDevicePropertyIsPrivate";
    case 'lcds':
        return "kAudioLevelControlPropertyConvertDecibelsToScalar";
    case 'lcsd':
        return "kAudioLevelControlPropertyConvertScalarToDecibels";
    case 'lcdr':
        return "kAudioLevelControlPropertyDecibelRange";
    case 'lcdv':
        return "kAudioLevelControlPropertyDecibelValue";
    case 'lcsv':
        return "kAudioLevelControlPropertyScalarValue";
    case 'bcls':
        return "kAudioObjectPropertyBaseClass";
    case 'clas':
        return "kAudioObjectPropertyClass";
    case 'ctrl':
        return "kAudioObjectPropertyControlList";
    case 'cust':
        return "kAudioObjectPropertyCustomPropertyInfoList";
    case 'fwvn':
        return "kAudioObjectPropertyFirmwareVersion";
    case 'iden':
        return "kAudioObjectPropertyIdentify";
    case 'lmak':
        return "kAudioObjectPropertyManufacturer";
    case 'lmod':
        return "kAudioObjectPropertyModelName";
    case 'lnam':
        return "kAudioObjectPropertyName";
    case 'ownd':
        return "kAudioObjectPropertyOwnedObjects";
    case 'stdv':
        return "kAudioObjectPropertyOwner";
    case '****':
        return "kAudioObjectPropertySelectorWildcard";
    case 'snum':
        return "kAudioObjectPropertySerialNumber";
    case 'box#':
        return "kAudioPlugInPropertyBoxList";
    case 'piid':
        return "kAudioPlugInPropertyBundleID";
    case 'clk#':
        return "kAudioPlugInPropertyClockDeviceList";
    case 'dev#':
        return "kAudioPlugInPropertyDeviceList";
    case 'rsrc':
        return "kAudioPlugInPropertyResourceBundle";
    case 'uidb':
        return "kAudioPlugInPropertyTranslateUIDToBox";
    case 'uidc':
        return "kAudioPlugInPropertyTranslateUIDToClockDevice";
    case 'uidd':
        return "kAudioPlugInPropertyTranslateUIDToDevice";
    case 'scai':
        return "kAudioSelectorControlPropertyAvailableItems";
    case 'scci':
        return "kAudioSelectorControlPropertyCurrentItem";
    case 'clkk':
        return "kAudioSelectorControlPropertyItemKind";
    case 'scin':
        return "kAudioSelectorControlPropertyItemName";
    case 'sdrr':
        return "kAudioSliderControlPropertyRange";
    case 'sdrv':
        return "kAudioSliderControlPropertyValue";
    case 'spcc':
        return "kAudioStereoPanControlPropertyPanningChannels";
    case 'spcv':
        return "kAudioStereoPanControlPropertyValue";
    case 'pfta':
        return "kAudioStreamPropertyAvailablePhysicalFormats";
    case 'sfma':
        return "kAudioStreamPropertyAvailableVirtualFormats";
    case 'sdir':
        return "kAudioStreamPropertyDirection";
    case 'sact':
        return "kAudioStreamPropertyIsActive";
    case 'schn':
        return "kAudioStreamPropertyStartingChannel";
    case 'term':
        return "kAudioStreamPropertyTerminalType";
    case 'sfmt':
        return "kAudioStreamPropertyVirtualFormat";
    case 'end#':
        return "kAudioTransportManagerPropertyEndPointList";
    case 'uide':
        return "kAudioTransportManagerPropertyTranslateUIDToEndPoint";
    default:
        return CodeToString(selector);
    }
}

std::string PropertyScopeToString(AudioObjectPropertyScope scope)
{
    switch (scope) {
    case 'glob':
        return "kAudioObjectPropertyScopeGlobal";
    case 'inpt':
        return "kAudioObjectPropertyScopeInput";
    case 'outp':
        return "kAudioObjectPropertyScopeOutput";
    case 'ptru':
        return "kAudioObjectPropertyScopePlayThrough";
    case '****':
        return "kAudioObjectPropertyScopeWildcard";
    default:
        return CodeToString(scope);
    }
}

std::string OperationIDToString(UInt32 operationID)
{
    switch (operationID) {
    case 'cinp':
        return "kAudioServerPlugInIOOperationConvertInput";
    case 'cmix':
        return "kAudioServerPlugInIOOperationConvertMix";
    case 'cycl':
        return "kAudioServerPlugInIOOperationCycle";
    case 'mixo':
        return "kAudioServerPlugInIOOperationMixOutput";
    case 'pinp':
        return "kAudioServerPlugInIOOperationProcessInput";
    case 'pmix':
        return "kAudioServerPlugInIOOperationProcessMix";
    case 'pout':
        return "kAudioServerPlugInIOOperationProcessOutput";
    case 'read':
        return "kAudioServerPlugInIOOperationReadInput";
    case 'thrd':
        return "kAudioServerPlugInIOOperationThread";
    case 'rite':
        return "kAudioServerPlugInIOOperationWriteMix";
    default:
        return CodeToString(operationID);
    }
}

std::string StatusToString(OSStatus status)
{
    switch (status) {
    case kAudioHardwareNoError:
        return "OK";
    case '!hog':
        return "kAudioDevicePermissionsError";
    case '!dat':
        return "kAudioDeviceUnsupportedFormatError";
    case '!dev':
        return "kAudioHardwareBadDeviceError";
    case '!obj':
        return "kAudioHardwareBadObjectError";
    case '!siz':
        return "kAudioHardwareBadPropertySizeError";
    case '!str':
        return "kAudioHardwareBadStreamError";
    case 'nope':
        return "kAudioHardwareIllegalOperationError";
    case 'nrdy':
        return "kAudioHardwareNotReadyError";
    case 'stop':
        return "kAudioHardwareNotRunningError";
    case 'who?':
        return "kAudioHardwareUnknownPropertyError";
    case 'what':
        return "kAudioHardwareUnspecifiedError";
    case 'unop':
        return "kAudioHardwareUnsupportedOperationError";
    case '!pth':
        return "kAudio_BadFilePathError";
    default:
        return CodeToString(UInt32(status));
    }
}

std::string FormatIDToString(AudioFormatID fmtid2code)
{
    switch (fmtid2code) {
    case 'cac3':
        return "kAudioFormat60958AC3";
    case 'ac-3':
        return "kAudioFormatAC3";
    case 'aes3':
        return "kAudioFormatAES3";
    case 'alaw':
        return "kAudioFormatALaw";
    case 'samr':
        return "kAudioFormatAMR";
    case 'sawb':
        return "kAudioFormatAMR_WB";
    case 'apac':
        return "kAudioFormatAPAC";
    case 'ima4':
        return "kAudioFormatAppleIMA4";
    case 'alac':
        return "kAudioFormatAppleLossless";
    case 'AUDB':
        return "kAudioFormatAudible";
    case 0x6D730011:
        return "kAudioFormatDVIIntelIMA";
    case 'ec-3':
        return "kAudioFormatEnhancedAC3";
    case 'flac':
        return "kAudioFormatFLAC";
    case 'lpcm':
        return "kAudioFormatLinearPCM";
    case 'MAC3':
        return "kAudioFormatMACE3";
    case 'MAC6':
        return "kAudioFormatMACE6";
    case 'midi':
        return "kAudioFormatMIDIStream";
    case 'aac ':
        return "kAudioFormatMPEG4AAC";
    case 'aace':
        return "kAudioFormatMPEG4AAC_ELD";
    case 'aacf':
        return "kAudioFormatMPEG4AAC_ELD_SBR";
    case 'aacg':
        return "kAudioFormatMPEG4AAC_ELD_V2";
    case 'aach':
        return "kAudioFormatMPEG4AAC_HE";
    case 'aacp':
        return "kAudioFormatMPEG4AAC_HE_V2";
    case 'aacl':
        return "kAudioFormatMPEG4AAC_LD";
    case 'aacs':
        return "kAudioFormatMPEG4AAC_Spatial";
    case 'celp':
        return "kAudioFormatMPEG4CELP";
    case 'hvxc':
        return "kAudioFormatMPEG4HVXC";
    case 'twvq':
        return "kAudioFormatMPEG4TwinVQ";
    case 'usac':
        return "kAudioFormatMPEGD_USAC";
    case '.mp1':
        return "kAudioFormatMPEGLayer1";
    case '.mp2':
        return "kAudioFormatMPEGLayer2";
    case '.mp3':
        return "kAudioFormatMPEGLayer3";
    case 0x6D730031:
        return "kAudioFormatMicrosoftGSM";
    case 'opus':
        return "kAudioFormatOpus";
    case 'apvs':
        return "kAudioFormatParameterValueStream";
    case 'QDMC':
        return "kAudioFormatQDesign";
    case 'QDM2':
        return "kAudioFormatQDesign2";
    case 'Qclp':
        return "kAudioFormatQUALCOMM";
    case 'time':
        return "kAudioFormatTimeCode";
    case 'ulaw':
        return "kAudioFormatULaw";
    case 'ilbc':
        return "kAudioFormatiLBC";
    default:
        return CodeToString(fmtid2code);
    }
}

std::string FormatFlagsToString(AudioFormatFlags formatFlags)
{
    std::string ret;
    if (formatFlags & (1U << 4)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsAlignedHigh";
    }
    if (formatFlags & (1U << 1)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsBigEndian";
    }
    if (formatFlags & (1U << 0)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsFloat";
    }
    if (formatFlags & (1U << 5)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsNonInterleaved";
    }
    if (formatFlags & (1U << 6)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsNonMixable";
    }
    if (formatFlags & (1U << 3)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsPacked";
    }
    if (formatFlags & (1U << 2)) {
        if (!ret.empty()) {
            ret += "|";
        }
        ret += "kAudioFormatFlagIsSignedInteger";
    }
    return ret;
}

} // namespace aspl
