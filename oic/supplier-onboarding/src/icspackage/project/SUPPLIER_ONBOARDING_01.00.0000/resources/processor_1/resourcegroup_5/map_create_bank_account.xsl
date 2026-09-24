<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <xsl:variable name="bank" select="$req/src:bankAccount"/>
      <erp:ExternalBankAccount>
         <erp:BankName><xsl:value-of select="$bank/src:bankName"/></erp:BankName>
         <erp:BankBranchName><xsl:value-of select="$bank/src:branchName"/></erp:BankBranchName>
         <erp:BankAccountNumber><xsl:value-of select="replace($bank/src:accountNumber, '\s', '')"/></erp:BankAccountNumber>
         <xsl:if test="$bank/src:iban[normalize-space()]"><erp:IBAN><xsl:value-of select="upper-case(replace($bank/src:iban, '\s', ''))"/></erp:IBAN></xsl:if>
         <erp:AccountName><xsl:value-of select="($bank/src:accountName[normalize-space()], $req/src:supplierName)[1]"/></erp:AccountName>
         <!-- Bank country defaults to the supplier address country -->
         <erp:CountryCode><xsl:value-of select="upper-case(($bank/src:countryCode[normalize-space()], $req/src:address/src:country)[1])"/></erp:CountryCode>
         <xsl:if test="$bank/src:currencyCode[normalize-space()]"><erp:CurrencyCode><xsl:value-of select="upper-case($bank/src:currencyCode)"/></erp:CurrencyCode></xsl:if>
         <xsl:if test="$bank/src:accountType[normalize-space()]"><erp:AccountType><xsl:value-of select="$bank/src:accountType"/></erp:AccountType></xsl:if>
         <erp:accountOwners>
            <erp:AccountOwnerPartyIdentifier><xsl:value-of select="$CreateSupplier/erp:Supplier/erp:SupplierPartyId"/></erp:AccountOwnerPartyIdentifier>
            <erp:PrimaryOwnerIndicator>Y</erp:PrimaryOwnerIndicator>
         </erp:accountOwners>
      </erp:ExternalBankAccount>
   </xsl:template>
</xsl:stylesheet>
